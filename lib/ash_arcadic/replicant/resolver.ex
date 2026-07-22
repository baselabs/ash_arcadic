defmodule AshArcadic.Replicant.Resolver do
  @moduledoc """
  Runtime resolution for the `AshArcadic.Replicant` sink — the tenant/classification
  layer over compiled resource metadata. Pure functions (no DB access):

    * `build_index/1` — reflect the configured domains into a
      `{source_schema, source_table} => resource` index, failing closed on a
      duplicate source key (an ambiguous route: two mirrors claiming one Postgres
      table).
    * `lookup/3` — resolve a source `{schema, table}` to its mirror resource,
      applying the SAME `nil`-schema → `"public"` default the index keys use.
    * `resolve_tenant/2` / `resolve_tenant!/3` — per-row tenant from the resource's
      replicant `tenant_attribute`, failing closed with `:tenant_required` on any
      value Ash would treat as unscoped (nil, `false`, or blank). `resolve_tenant!/3`
      is the raising variant every apply path shares.
    * `writable_target/2` / `attrs_for_upsert/2` — map source string columns to their
      writable target attributes, dropping replicant-`skip` columns and undeclared
      columns, and HALTING value-free (F5) when a non-skipped column maps to a
      `sensitive` target (never emit plaintext into a classified column).
    * `primary_key/1` / `pk_values/2`.

  Diverges from the sibling `ash_replicant`'s `AshReplicant.Resolver` (the shape
  template) deliberately:

    * Source records are **string-keyed** (Postgres column names as binaries), so
      every lookup is `Map.get(record, to_string(attr))`.
    * No `tenant_mfa` — the replicant extension exposes only `tenant_attribute`.
    * No AshCloak cloak-routing. AshArcadic has no key material, so a plaintext value
      bound for a `sensitive` target fails closed (F5) rather than being re-encrypted.
  """

  alias AshArcadic.DataLayer.Info, as: DataLayerInfo
  alias AshArcadic.Replicant.Error
  alias AshArcadic.Replicant.Info

  @type source_key :: {schema :: String.t(), table :: String.t()}

  @spec build_index([module()]) ::
          {:ok, %{source_key() => module()}}
          | {:error, {:duplicate_source, source_key()}}
          | {:error, {:missing_source_table, module()}}
  def build_index(domains) when is_list(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&replicant_resource?/1)
    |> Enum.reduce_while({:ok, %{}}, &index_resource/2)
  end

  @doc """
  Look up the mirror resource for a source `{schema, table}` in an index built by
  `build_index/1`, applying the SAME `nil`-schema → `"public"` default the index
  keys use (so the convention lives in one place next to the builder). Returns the
  resource, or `nil` for an unmapped table.
  """
  @spec lookup(%{source_key() => module()}, String.t() | nil, String.t()) :: module() | nil
  def lookup(index, schema, table), do: Map.get(index, {schema || "public", table})

  @spec resolve_tenant(module(), map()) :: {:ok, term()} | {:error, :tenant_required}
  def resolve_tenant(resource, record) when is_map(record) do
    case Info.tenant_attribute(resource) do
      nil -> {:ok, nil}
      attr -> record |> Map.get(to_string(attr)) |> present_or_required()
    end
  end

  @doc """
  The fail-closed bang variant of `resolve_tenant/2`: returns the per-row tenant, or
  raises a value-free `AshArcadic.Replicant.Error` (`reason: :tenant_required`) when
  the row carries no usable tenant. `op` labels the failing sink operation
  (`:upsert` / `:destroy` / ...) in the structural error, which NEVER carries the
  record or the tenant value. The single tenant-resolution entry point shared by
  every apply path, so `:tenant_required` fails identically everywhere.
  """
  @spec resolve_tenant!(module(), map(), atom()) :: term()
  def resolve_tenant!(resource, record, op) do
    case resolve_tenant(resource, record) do
      {:ok, tenant} ->
        tenant

      {:error, :tenant_required} ->
        raise Error.exception(reason: :tenant_required, resource: resource, op: op)
    end
  end

  @spec writable_target(module(), String.t()) :: {:ok, atom()} | :skip
  def writable_target(resource, source_col) when is_binary(source_col) do
    classify(resource, source_col, reflection(resource))
  end

  @doc """
  Map one string-keyed source `record` to `{inputs, upsert_fields}` for the mirror
  upsert. Drops replicant-`skip` columns and undeclared columns; unchanged-TOAST
  columns are absent from `record` (surfaced separately on `%Replicant.Change{}`'s
  `unchanged` list, never in `record`) so iterating the map excludes them naturally.
  HALTS value-free (F5) on a non-skipped column mapped to a `sensitive` target.
  """
  @spec attrs_for_upsert(module(), map()) :: {map(), [atom()]}
  def attrs_for_upsert(resource, record) when is_atom(resource) and is_map(record) do
    ref = reflection(resource)

    {inputs, fields} =
      Enum.reduce(record, {%{}, []}, fn {col, value}, {inputs, fields} ->
        case classify(resource, col, ref) do
          {:ok, atom} -> {Map.put(inputs, atom, value), [atom | fields]}
          :skip -> {inputs, fields}
        end
      end)

    {inputs, fields |> Enum.reverse() |> Enum.uniq()}
  end

  @spec primary_key(module()) :: [atom()]
  def primary_key(resource), do: Ash.Resource.Info.primary_key(resource)

  @spec pk_values(module(), map()) :: map()
  def pk_values(resource, record) when is_map(record) do
    resource |> primary_key() |> Map.new(fn k -> {k, Map.get(record, to_string(k))} end)
  end

  # --- private ---

  @typep reflection :: {skip :: [atom()], sensitive :: [atom()], attrs :: MapSet.t(atom())}

  @spec reflection(module()) :: reflection()
  defp reflection(resource) do
    {Info.skip(resource), DataLayerInfo.sensitive(resource), attribute_names(resource)}
  end

  # Classify one source column against a precomputed reflection: `{:ok, target_atom}`
  # to write, or `:skip` to drop. Replicant-`skip` wins first (the documented safe
  # config for a sensitive source column). A non-skipped column mapped to a
  # `sensitive` target HALTS value-free (F5): the arriving Postgres value is plaintext
  # and AshArcadic holds no key to encrypt it, so emitting it would write plaintext
  # into a classified column. ValidateSensitive R2 already guarantees the target is
  # binary-storage-typed at compile, and a plaintext string is itself a binary — so
  # there is no runtime value check that could safely admit it; the only fail-closed
  # form is to refuse every non-skipped sensitive column and require it be skipped.
  @spec classify(module(), String.t(), reflection()) :: {:ok, atom()} | :skip
  defp classify(resource, source_col, {skip, sensitive, attrs}) do
    col = to_existing_atom(source_col)

    cond do
      is_nil(col) -> :skip
      col in skip -> :skip
      col in sensitive -> raise Error.exception(reason: :sensitive_plaintext, resource: resource)
      MapSet.member?(attrs, col) -> {:ok, col}
      true -> :skip
    end
  end

  @spec index_resource(module(), {:ok, %{source_key() => module()}}) ::
          {:cont, {:ok, %{source_key() => module()}}}
          | {:halt, {:error, {:duplicate_source, source_key()}}}
          | {:halt, {:error, {:missing_source_table, module()}}}
  defp index_resource(resource, {:ok, acc}) do
    case source_key(resource) do
      {:ok, key} -> put_source(acc, key, resource)
      :error -> {:halt, {:error, {:missing_source_table, resource}}}
    end
  end

  defp put_source(acc, key, resource) do
    if Map.has_key?(acc, key) do
      {:halt, {:error, {:duplicate_source, key}}}
    else
      {:cont, {:ok, Map.put(acc, key, resource)}}
    end
  end

  # The `{:ok, table} | :error` union of the required `source_table` option is handled
  # in full and fails closed on `:error` → `{:missing_source_table, resource}`.
  @spec source_key(module()) :: {:ok, source_key()} | :error
  defp source_key(resource) do
    case Info.replicant_source_table(resource) do
      {:ok, table} when is_binary(table) -> {:ok, {Info.source_schema(resource), table}}
      _ -> :error
    end
  end

  defp replicant_resource?(resource) do
    AshArcadic.Replicant in Spark.extensions(resource)
  rescue
    _ -> false
  end

  defp attribute_names(resource) do
    resource |> Ash.Resource.Info.attributes() |> MapSet.new(& &1.name)
  end

  defp to_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp present_or_required(nil), do: {:error, :tenant_required}

  # `false` is the only other Elixir falsy value. Ash treats a falsy tenant as NO
  # scoping — `handle_attribute_multitenancy` guards `if changeset.tenant` — so a
  # `false` tenant is neither force-set nor rejected and the mirror write lands
  # UNSCOPED. Fail closed, exactly like `nil` (stricter than `blank_tenant?/1`).
  defp present_or_required(false), do: {:error, :tenant_required}

  defp present_or_required(v) when is_binary(v),
    do: if(String.trim(v) == "", do: {:error, :tenant_required}, else: {:ok, v})

  defp present_or_required(v), do: {:ok, v}
end
