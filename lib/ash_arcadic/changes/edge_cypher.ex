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
    [dest_pk_attr] = Ash.Resource.Info.primary_key(destination)
    spec = Map.get(Info.attribute_types(destination), dest_pk_attr)
    Enum.map(dest_ids, &Cast.serialize_value(&1, spec))
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
  # For an `:attribute` source, the `{src_attr, dest_attr, value}` spec scoping BOTH
  # endpoints by the tenant discriminator; nil otherwise.
  def tenant_spec(resource, edge, changeset) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
      {Ash.Resource.Info.multitenancy_attribute(resource),
       Ash.Resource.Info.multitenancy_attribute(edge.destination), changeset.to_tenant}
    else
      nil
    end
  end

  @doc false
  # The tenant WHERE fragment. A non-multitenant destination (nil dest_attr) takes
  # no destination clause. Returns `{clause, params}`.
  def tenant_where(nil), do: {"", %{}}

  def tenant_where({src_attr, dest_attr, value}) do
    src = src_attr |> to_string() |> Identifier.validate!()
    dest = if dest_attr, do: dest_attr |> to_string() |> Identifier.validate!()

    clause = " AND a.#{src} = $tenant" <> if(dest, do: " AND b.#{dest} = $tenant", else: "")
    {clause, %{"tenant" => value}}
  end

  @doc false
  # Rule-4 fail-closed pre-gate over the FULL edge param map: `Jason.encode/1` every
  # value; return `{:error, key}` (naming only the attribute/param KEY, never the
  # value) for the first non-encodable one, else `:ok`. A raw non-UTF8 binary nested
  # in a `:map`/`:list` value (e.g. a non-sensitive `:map` property argument) would
  # otherwise raise `Jason.EncodeError` with the bytes in the message at the wire.
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
