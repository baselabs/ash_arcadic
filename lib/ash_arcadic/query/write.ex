defmodule AshArcadic.Query.Write do
  @moduledoc """
  Builds the Cypher `SET` clause for a query-scoped bulk write (`update_query`) and for the
  atomic surface of `create`/`upsert`, from an Ash changeset's atomic + static changes. Pure —
  no transport.

  `changeset.atomics` (`[{field, ash_expr}]`, e.g. `[age: %Plus{}]`) become `n.<field> = <cypher>`
  fragments — each RHS is HYDRATED (`Ash.Filter.hydrate_refs/2`, idempotent: `fully_atomic_changeset`
  pre-hydrates the `update_query`/upsert inputs, but `atomic_set`-on-create and unit-test-built
  atomics arrive as un-hydrated `%Ash.Query.Call{}`; hydration resolves both — live-verified
  `scratchpad/probe_hydrate_idempotent.exs`) then translated by `AshArcadic.Query.Expression`
  (which emits `n.<field>` for a stored ref and fails closed value-free on sensitive/non-stored/
  `:binary`/`:decimal`/relationship/aggregate refs and un-mapped ops). `changeset.attributes`
  (the statically-cast map) become `n += $static`. A write to the multitenancy discriminator
  (atomic OR static) is rejected value-free (a tenant-hop of the row); a fully-empty SET is
  rejected value-free. Every value rides a bound `$param` — the RHS via `Expression`/`add_param`,
  the static map as `$static` (Rule 1).
  """
  alias AshArcadic.Cast
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Errors.UnsupportedFilter
  alias AshArcadic.Identifier
  alias AshArcadic.Query
  alias AshArcadic.Query.Expression

  @doc """
  Builds `{:ok, set_clause, params}` from a changeset's atomic + static changes, or
  `{:error, %UnsupportedFilter{}}` fail-closed value-free. `seed_params` pre-seeds the
  `$paramN` accumulator (the WHERE clause's bound params) so an atomic RHS literal never
  collides with a WHERE param. When static changes are present, `params["static"]` carries
  the cast property map (for the caller's encode-gate) and the clause ends `…, n += $static`.
  """
  @spec build_set(Ash.Resource.t(), Ash.Changeset.t(), map()) ::
          {:ok, String.t(), map()} | {:error, Exception.t()}
  def build_set(resource, changeset, seed_params) do
    disc = discriminator(resource)
    # Seed a working query carrying the REAL resource so Expression.ref_ok?/2's sensitive/
    # non-stored guard fires (a resource-less %Query{} would bypass it — expression.ex:196).
    working = %Query{resource: resource, params: seed_params}

    with {:ok, atomic_frags, working} <- atomic_set(changeset.atomics, working, disc),
         {:ok, static_map} <- static_changes(resource, changeset, disc) do
      assemble(atomic_frags, static_map, working.params)
    end
  end

  @doc """
  Atomic SET fragments (`["n.<f> = <cypher>", …]`) + params for a list of `{field, hydrated_expr}`
  atomics, `seed_params`-threaded. Value-free fail-closed on a discriminator target or a
  sensitive/non-stored/un-mapped RHS. Shared by update_query (via build_set), atomic create, and
  atomic upsert.
  """
  @spec atomic_fragments(Ash.Resource.t(), keyword(), map()) ::
          {:ok, [String.t()], map()} | {:error, Exception.t()}
  def atomic_fragments(resource, atomics, seed_params) do
    disc = discriminator(resource)
    working = %Query{resource: resource, params: seed_params}

    case atomic_set(atomics, working, disc) do
      {:ok, frags, working} -> {:ok, frags, working.params}
      {:error, _} = err -> err
    end
  end

  # Fold each atomic {field, expr} into `["n.<field> = <cypher>", …]` + accumulated params. Shared
  # by build_set (update_query) and atomic_fragments/3 (atomic create/upsert). Extracted per-atomic
  # into translate_atomic/4 to keep the nesting ≤ credo's max depth 2.
  defp atomic_set(atomics, working, disc) do
    Enum.reduce_while(atomics, {:ok, [], working}, fn {field, expr}, {:ok, frags, q} ->
      case translate_atomic(field, expr, q, disc) do
        {:ok, frag, q} -> {:cont, {:ok, [frag | frags], q}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, frags, q} -> {:ok, Enum.reverse(frags), q}
      {:error, _} = err -> err
    end
  end

  # One atomic → `{:ok, "n.<field> = <cypher>", q}` | value-free `{:error, _}`. Two LHS-TARGET guards
  # fire before any RHS work (spec §7.1): a discriminator target is rejected value-free (a tenant-hop),
  # and a `sensitive`/non-stored target is rejected value-free — an atomic SET binds the RHS RAW (no
  # `Cast.serialize_value`/app-side encryption), so `n.<sensitive> = <expr>` would store PLAINTEXT into
  # an encrypted-binary field, and a non-stored target has no column to set. `Expression.translate`
  # guards RHS *refs* only, never the LHS target — so the target itself is guarded HERE via the Slice-7
  # `Info.value_translatable_field?/2` predicate (`stored AND not sensitive`; the discriminator IS
  # translatable, hence its own separate clause above). Then HYDRATE the expr (idempotent — resolves an
  # un-hydrated %Ash.Query.Call{} from atomic_set-on-create / test inputs AND passes an already-hydrated
  # %Plus{} through, probe_hydrate_idempotent.exs) and translate the RHS. `field` is identifier-validated
  # (only the NAME is interpolated).
  defp translate_atomic(field, _expr, _q, disc) when field == disc,
    do: {:error, discriminator_error(field)}

  defp translate_atomic(field, expr, q, _disc) do
    if Info.value_translatable_field?(q.resource, field) do
      translate_atomic_rhs(field, expr, q)
    else
      {:error, target_error(field)}
    end
  end

  defp translate_atomic_rhs(field, expr, q) do
    with {:ok, hydrated} <- Ash.Filter.hydrate_refs(expr, %{resource: q.resource, public?: false}),
         {:ok, q, rhs} <- Expression.translate(hydrated, q) do
      name = field |> to_string() |> Identifier.validate!()
      {:ok, "n.#{name} = #{rhs}", q}
    else
      {:error, %UnsupportedFilter{}} = err -> err
      {:error, _other} -> {:error, UnsupportedFilter.exception(operator: :atomic, field: field)}
    end
  end

  # The static property map (changeset.attributes minus `skip`), each value serialized by type.
  # A static write to the discriminator is rejected value-free (never SET the tenant key).
  defp static_changes(resource, changeset, disc) do
    skip = Info.skip(resource)
    types = Info.attribute_types(resource)

    if disc && Map.has_key?(changeset.attributes, disc) do
      {:error, discriminator_error(disc)}
    else
      map =
        changeset.attributes
        |> Enum.reject(fn {key, _value} -> key in skip end)
        |> Map.new(fn {key, value} ->
          {Atom.to_string(key), Cast.serialize_value(value, Map.get(types, key))}
        end)

      {:ok, map}
    end
  end

  # Assemble atomic fragments + (when non-empty) `n += $static`. A fully-empty SET fails closed
  # value-free (an update with no changes is a validation error, never a no-op statement).
  defp assemble([], static_map, _params) when static_map == %{} do
    {:error, UnsupportedFilter.exception(operator: :set, field: nil)}
  end

  defp assemble(atomic_frags, static_map, params) do
    {frags, params} =
      if static_map == %{} do
        {atomic_frags, params}
      else
        {atomic_frags ++ ["n += $static"], Map.put(params, "static", static_map)}
      end

    {:ok, Enum.join(frags, ", "), params}
  end

  # The :attribute multitenancy discriminator, or nil for :context / non-multitenant. `:context`
  # isolation is the physical database — its discriminator is never a settable property here.
  defp discriminator(resource) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
      Ash.Resource.Info.multitenancy_attribute(resource)
    end
  end

  # Value-free: the discriminator FIELD name is structural (a schema attribute name), never a value.
  defp discriminator_error(field),
    do: UnsupportedFilter.exception(operator: :set_discriminator, field: field)

  # Value-free: a `sensitive`/non-stored atomic SET target (spec §7.1). The field NAME is structural.
  defp target_error(field),
    do: UnsupportedFilter.exception(operator: :set_target, field: field)
end
