defmodule AshArcadic.Changes.CreateEdge do
  @moduledoc """
  Ash change that persists a graph edge from the action's record to a destination
  named by an argument, after the vertex write, inside the action's transaction.

      change {AshArcadic.Changes.CreateEdge, edge: :author, to: :author_id}

  `edge:` names an `edge` in the resource's `arcade do … end` block; `to:` names an
  action argument holding the destination PK (or a list → N edges; nil/empty → no
  edge, action still succeeds). Edge property values come from same-named DECLARED
  action arguments, serialized by the argument's declared type. `multiple? false`
  (default) MERGEs (idempotent); `multiple? true` CREATEs (parallel edges). A failed
  or 0-row write returns `{:error, _}` so Ash rolls the vertex back; DB errors are
  redacted (Rule 4). The R4 sensitive-property guard fires even on an empty `to:`.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidRelationship
  alias AshArcadic.Cast
  alias AshArcadic.Changes.EdgeCypher
  alias AshArcadic.DataLayer
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Identifier
  alias AshArcadic.Telemetry

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      run(changeset, record, opts)
    end)
  end

  @doc false
  def run(changeset, record, opts) do
    resource = changeset.resource
    start = %{resource: resource, multitenancy: Ash.Resource.Info.multitenancy_strategy(resource)}

    Telemetry.span(:create_edge, start, fn ->
      edge = EdgeCypher.fetch_edge!(resource, Keyword.fetch!(opts, :edge))
      dest_ids = destination_ids(changeset, opts)

      # R4 runtime guard is evaluated BEFORE the empty-`to:` no-op: a sensitive
      # property handed to a plaintext/undeclared arg is a misdeclaration whether or
      # not an edge would be written (matches the compile half's declaration-level
      # semantics). Never `if dest_ids == [] first`.
      {result, properties?} =
        case edge_properties(changeset, edge) do
          {:ok, props} ->
            {write_edges(changeset, record, resource, edge, dest_ids, props), map_size(props) > 0}

          {:error, key} ->
            {sensitive_property_error(edge, key), false}
        end

      {result,
       %{
         destination_count: length(dest_ids),
         direction: edge.direction,
         properties?: properties?,
         tenant?: not is_nil(changeset.to_tenant),
         result: Telemetry.result_tag(result)
       }}
    end)
  end

  defp write_edges(changeset, record, resource, edge, dest_ids, props) do
    case DataLayer.write_conn(resource, changeset) do
      {:ok, conn} ->
        tenant = EdgeCypher.tenant_spec(resource, edge, changeset)
        src_key = EdgeCypher.source_key(resource, record)
        dest_ids = EdgeCypher.serialize_destination_ids(edge.destination, dest_ids)
        create_all(conn, record, dest_ids, resource, edge, src_key, props, tenant)

      {:error, reason} ->
        {:error,
         InvalidRelationship.exception(
           relationship: edge.name,
           message: EdgeCypher.conn_reason(reason)
         )}
    end
  end

  # Value-free by construction: names the KEY only, never the value.
  defp sensitive_property_error(edge, key) do
    {:error,
     InvalidRelationship.exception(
       relationship: edge.name,
       message:
         "sensitive property #{inspect(key)} requires a binary-storage-typed declared " <>
           "action argument (value withheld)"
     )}
  end

  # One edge per destination id, halting (and returning the error so Ash rolls the
  # vertex back) on the first failed or 0-row write. The loop runs inside the action
  # transaction, so a mid-list halt rolls all prior edges back.
  defp create_all(conn, record, dest_ids, resource, edge, src_key, props, tenant) do
    Enum.reduce_while(dest_ids, {:ok, record}, fn dest_id, {:ok, rec} ->
      case create_one(conn, resource, edge, src_key, dest_id, props, tenant) do
        {:ok, _} -> {:cont, {:ok, rec}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp create_one(conn, resource, edge, src_key, dest_id, props, tenant) do
    {cypher, params} = build_create(resource, edge, src_key, dest_id, props, tenant)

    case EdgeCypher.encode_gate(params) do
      {:error, key} ->
        {:error,
         InvalidRelationship.exception(
           relationship: edge.name,
           message: EdgeCypher.encode_reason(key)
         )}

      :ok ->
        case Arcadic.command(conn, cypher, params) do
          {:ok, [_ | _]} ->
            # A non-empty MATCH bound the tenant-scoped endpoints and applied the
            # MERGE/CREATE; endpoint-PK uniqueness is a host-app index concern
            # (usage-rules), not a data-layer guarantee.
            {:ok, :created}

          {:ok, []} ->
            {:error,
             InvalidRelationship.exception(
               relationship: edge.name,
               message: "destination not found in the source's tenant scope"
             )}

          {:error, error} ->
            {:error,
             InvalidRelationship.exception(
               relationship: edge.name,
               message: DataLayer.redact_db_error(error)
             )}
        end
    end
  end

  @doc false
  # Pure Cypher builder — unit-tested. `src_key` is a map of source PK field (string)
  # => value; `tenant` is nil or {src_attr, dest_attr, value}. dest_id is already
  # serialized (serialize_destination_ids). WHERE scopes BOTH endpoints BEFORE the
  # MERGE/CREATE-rel — inlining the identity into the node pattern would re-open the
  # vertex-MERGE cross-tenant hole (data_layer.ex do_upsert/merge_identity). LOCKED
  # INVARIANT.
  def build_create(resource, edge, src_key, dest_id, props, tenant) do
    src_label = EdgeCypher.validated_label(resource)
    dest_label = EdgeCypher.validated_label(edge.destination)
    edge_label = Identifier.validate!(edge.label)
    dest_pk = EdgeCypher.destination_pk!(edge.destination)

    {src_where, src_params} = EdgeCypher.source_where(src_key)
    {tenant_where, tenant_params} = EdgeCypher.tenant_where(tenant)
    stamp = if tenant, do: ", e.#{tenant_attr(tenant)} = $tenant", else: ""

    arrow =
      case edge.direction do
        :incoming -> "(b)-[e:#{edge_label}]->(a)"
        _ -> "(a)-[e:#{edge_label}]->(b)"
      end

    write =
      if edge.multiple? do
        "CREATE #{arrow} SET e += $props#{stamp}"
      else
        "MERGE #{arrow} ON CREATE SET e += $props#{stamp} ON MATCH SET e += $props"
      end

    cypher =
      "MATCH (a:#{src_label}), (b:#{dest_label}) " <>
        "WHERE #{src_where} AND b.#{dest_pk} = $dst#{tenant_where} " <>
        "#{write} RETURN e"

    params =
      src_params
      |> Map.put("dst", dest_id)
      |> Map.put("props", props)
      |> Map.merge(tenant_params)

    {cypher, params}
  end

  @doc false
  # Pure fn of (changeset, opts) — the destination PK(s) from `to:` as a list: a
  # single key → one edge, a list → N, nil/unsupplied → [].
  def destination_ids(changeset, opts) do
    List.wrap(Ash.Changeset.get_argument(changeset, Keyword.fetch!(opts, :to)))
  end

  @doc false
  # Pure fn of (changeset, edge) — each edge property's value from the same-named
  # action argument, rejecting nil (sparse), serialized by the DECLARED argument
  # type. Returns `{:error, key}` (fail closed, value-free) when a `sensitive` key
  # has no binary-storage-typed declared argument backing it — the R4 runtime half.
  def edge_properties(changeset, edge) do
    arg_types = argument_types(changeset)
    sensitive = Info.sensitive(changeset.resource)

    edge.properties
    |> Enum.map(fn key -> {key, Ash.Changeset.get_argument(changeset, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      {type, constraints} = Map.get(arg_types, key, {nil, []})
      # An undeclared/injected arg has no type. Serialize it through a BARE `nil`
      # spec (Cast.normalize_spec(nil) → :untyped pass-through), NOT the `{nil, []}`
      # tuple — the tuple routes into Ash.Type.storage_type(nil, _), which raises
      # for a non-sensitive binary property. The R4 sensitive guard below still
      # fails closed on the nil type.
      spec = if is_nil(type), do: nil, else: {type, constraints}

      if key in sensitive and (is_nil(type) or not Cast.binary_storage?(type, constraints)) do
        {:halt, {:error, key}}
      else
        {:cont, {:ok, Map.put(acc, Atom.to_string(key), Cast.serialize_value(value, spec))}}
      end
    end)
  end

  defp argument_types(%{action: %{arguments: arguments}}) when is_list(arguments) do
    Map.new(arguments, fn %{name: name, type: type} = arg ->
      {name, {type, Map.get(arg, :constraints) || []}}
    end)
  end

  defp argument_types(_changeset), do: %{}

  defp tenant_attr({src_attr, _dest_attr, _value}), do: Identifier.validate!(to_string(src_attr))
end
