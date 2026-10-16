defmodule AshArcadic.Changes.EdgeCypher do
  @moduledoc false
  # Shared, security-critical builders for the edge change modules
  # (AshArcadic.Changes.CreateEdge / DestroyEdge). Both build parameterized edge
  # Cypher from the SAME endpoint identification, identifier validation, and
  # tenant-scoping rules; keeping that in ONE place prevents the two modules'
  # tenant/injection clauses from diverging (a divergence in tenant_where/1 would
  # be a cross-tenant write hole). Ported from ../ash_age/lib/changes/edge_cypher.ex,
  # replacing the agtype/Parameterized machinery with the arcadic identifier/cast
  # substrate and a JSON encode-gate (Rule 4).

  alias AshArcadic.Cast
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Identifier

  @doc false
  # Resolves the named edge on the resource, raising if it isn't declared.
  def fetch_edge!(resource, name) do
    case Enum.find(Info.edges(resource), &(&1.name == name)) do
      %AshArcadic.Edge{} = edge -> edge
      nil -> raise ArgumentError, "no `edge #{inspect(name)}` declared on #{inspect(resource)}"
    end
  end

  @doc false
  # The resource's vertex label, validated as an ArcadeDB identifier.
  def validated_label(resource), do: resource |> Info.label() |> Identifier.validate!()

  @doc false
  # The destination's single-attribute primary-key name, validated. Edge
  # destinations must have a single-attribute PK.
  def destination_pk!(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [single] -> single |> to_string() |> Identifier.validate!()
      _ -> raise ArgumentError, "edge destinations must have a single-attribute primary key"
    end
  end

  @doc false
  # Destination endpoint values serialized by the DESTINATION RESOURCE's PK
  # attribute type (resolved once for the whole list). Single-attribute PK is
  # enforced by destination_pk! at the build site.
  def serialize_destination_ids(destination, dest_ids) do
    case Ash.Resource.Info.primary_key(destination) do
      [dest_pk_attr] ->
        spec = Map.get(Info.attribute_types(destination), dest_pk_attr)
        Enum.map(dest_ids, &Cast.serialize_value(&1, spec))

      # Fail with the SAME value-free message as destination_pk! rather than letting a
      # `[single] = pk` destructure raise a cryptic MatchError first at the write site.
      _ ->
        raise ArgumentError, "edge destinations must have a single-attribute primary key"
    end
  end

  @doc false
  # A map of source PK field (string) => value, read from the PERSISTED record (its
  # original identity), serialized by the SOURCE RESOURCE's attribute types so the
  # WHERE matches the stored wire form.
  def source_key(resource, record) do
    types = Info.attribute_types(resource)

    resource
    |> Ash.Resource.Info.primary_key()
    |> Map.new(fn f ->
      {to_string(f), Cast.serialize_value(Map.get(record, f), Map.get(types, f))}
    end)
  end

  @doc false
  # Source WHERE clause (`a.<pk> = $src_<pk>`), each field identifier-validated and
  # each value bound as a $param. Returns `{clause, params}`.
  def source_where(src_key) do
    {clauses, params} =
      Enum.reduce(src_key, {[], %{}}, fn {field, value}, {clauses, params} ->
        field = Identifier.validate!(field)
        key = "src_#{field}"
        {["a.#{field} = $#{key}" | clauses], Map.put(params, key, value)}
      end)

    {clauses |> Enum.reverse() |> Enum.join(" AND "), params}
  end

  @doc false
  # Tenant scoping for an edge write, decided per ENDPOINT (mirrors traverse.ex's
  # scope_decision — the same invariant on the write surface). Every `:attribute`
  # endpoint — source, destination, or both — is scoped by its OWN discriminator: the
  # value is that resource's `parse_attribute(to_tenant)`, serialized by that attribute's
  # type (the exact normalization the vertex write path stores), bound as its own $param.
  # A destination-only `:attribute` multitenancy previously produced NO tenant clause at
  # all — the MATCH bound the victim tenant's vertex by bare PK (a cross-tenant edge
  # write; review 2026-10-16). A blank tenant on any `:attribute` endpoint fails closed
  # `{:error, :tenant_required}`. `:context` endpoints scope at the DATABASE level
  # (write_conn resolves the per-tenant database), so they take no attribute clause.
  # Returns `{:ok, nil}` when neither endpoint is `:attribute`, else
  # `{:ok, %{src: {attr, bound}} and/or %{dest: {attr, bound}}}`.
  def tenant_spec(resource, edge, changeset) do
    with {:ok, src_scope} <- endpoint_scope(resource, changeset),
         {:ok, dest_scope} <- endpoint_scope(edge.destination, changeset) do
      scope =
        %{}
        |> Map.put(:src, src_scope)
        |> Map.put(:dest, dest_scope)
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      {:ok, if(scope == %{}, do: nil, else: scope)}
    end
  end

  defp endpoint_scope(resource, changeset) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
      case changeset.to_tenant do
        tenant when tenant in [nil, ""] ->
          {:error, :tenant_required}

        tenant ->
          attr = Ash.Resource.Info.multitenancy_attribute(resource)
          {m, f, a} = Ash.Resource.Info.multitenancy_parse_attribute(resource)
          # The same normalize -> parse -> serialize composition as the vector and
          # update_many tenant predicates (sibling parity): the discriminator a vertex
          # row stores is serialize(parse(to_tenant)).
          value =
            tenant
            |> Ash.ToTenant.to_tenant(resource)
            |> then(&apply(m, f, [&1 | a]))
            |> Cast.serialize_value(Map.get(Info.attribute_types(resource), attr))

          {:ok, {attr, value}}
      end
    else
      {:ok, nil}
    end
  end

  @doc false
  # The tenant WHERE fragment over the scope built by tenant_spec/3. The SOURCE binds
  # `$tenant` (unchanged name — the edge stamp in build_create uses it), a scoped
  # destination binds its own `$tenant_dest`. Returns `{clause, params}`.
  def tenant_where(nil), do: {"", %{}}

  def tenant_where(%{} = scope) do
    # Fixed [:src, :dest] render order (NOT map iteration order) so the emitted Cypher
    # is deterministic and reads source-first.
    {clauses, params} =
      Enum.reduce([:src, :dest], {[], %{}}, fn side, {clauses, params} ->
        case scope do
          %{^side => {attr, value}} when side == :src ->
            src = attr |> to_string() |> Identifier.validate!()
            {["a.#{src} = $tenant" | clauses], Map.put(params, "tenant", value)}

          %{^side => {attr, value}} ->
            dest = attr |> to_string() |> Identifier.validate!()
            {["b.#{dest} = $tenant_dest" | clauses], Map.put(params, "tenant_dest", value)}

          _ ->
            {clauses, params}
        end
      end)

    {" AND " <> (clauses |> Enum.reverse() |> Enum.join(" AND ")), params}
  end

  @doc false
  # Rule-4 fail-closed pre-gate over the FULL edge param map: `Jason.encode/1` every
  # value; return `{:error, key}` (naming only the attribute/param KEY, never the
  # value) for the first non-encodable one, else `:ok`. A raw non-UTF8 binary nested
  # in a `:map`/`:list` value (e.g. a non-sensitive `:map` property argument) would
  # otherwise surface only at the wire — a generic typed `:invalid_params` under
  # arcadic >= 1.2, a byte-echoing `Jason.EncodeError` raise on 1.1.
  # Mirrors AshArcadic.DataLayer.encode_check + traverse.ex check_ids_encodable.
  def encode_gate(params) do
    Enum.find_value(params, :ok, fn {key, value} ->
      case Jason.encode(value) do
        {:ok, _} -> nil
        {:error, _} -> {:error, key}
      end
    end)
  end

  @doc false
  # Value-free message naming only the offending param KEY (never its value) when the
  # encode-gate rejects a param. Shared by CreateEdge/DestroyEdge so the two cannot drift.
  def encode_reason(key) do
    "edge parameter #{inspect(key)} is not JSON-encodable (raw binary nested in a " <>
      ":map/:list value? encode it app-side or use a :binary-typed argument)"
  end

  @doc false
  # Value-free message for a `write_conn` error reason. Shared home (anti-divergence):
  # a per-module fork of these clauses would let the two change modules' tenant/txn
  # error text drift.
  def conn_reason(:tenant_required), do: "tenant required"
  def conn_reason(:cross_database_transaction), do: "transaction spans multiple databases"
  def conn_reason(:transaction_begin_failed), do: "could not begin ArcadeDB transaction"
end
