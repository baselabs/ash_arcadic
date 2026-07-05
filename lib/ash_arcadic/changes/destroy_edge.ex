defmodule AshArcadic.Changes.DestroyEdge do
  @moduledoc """
  Ash change that removes a graph edge from the action's record to a destination
  named by an argument, after the vertex write, inside the action's transaction.

      change {AshArcadic.Changes.DestroyEdge, edge: :author, to: :author_id}

  An edge that matched nothing (already gone or out of the source's tenant scope)
  returns `Ash.Error.Changes.StaleRecord` so Ash rolls the vertex back; DB errors
  are redacted. nil/empty `to:` removes no edge and the action still succeeds.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidRelationship
  alias Ash.Error.Changes.StaleRecord
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshArcadic.Changes.EdgeCypher
  alias AshArcadic.DataLayer
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
    start = %{resource: resource, multitenancy: ResourceInfo.multitenancy_strategy(resource)}

    Telemetry.span(:destroy_edge, start, fn ->
      edge = EdgeCypher.fetch_edge!(resource, Keyword.fetch!(opts, :edge))
      dest_ids = List.wrap(Ash.Changeset.get_argument(changeset, Keyword.fetch!(opts, :to)))

      result =
        case DataLayer.write_conn(resource, changeset) do
          {:ok, conn} ->
            tenant = EdgeCypher.tenant_spec(resource, edge, changeset)
            src_key = EdgeCypher.source_key(resource, record)
            serialized = EdgeCypher.serialize_destination_ids(edge.destination, dest_ids)
            destroy_all(conn, record, serialized, resource, edge, src_key, tenant)

          {:error, reason} ->
            {:error,
             InvalidRelationship.exception(relationship: edge.name, message: conn_reason(reason))}
        end

      {result,
       %{
         destination_count: length(dest_ids),
         direction: edge.direction,
         tenant?: not is_nil(changeset.to_tenant),
         result: Telemetry.result_tag(result)
       }}
    end)
  end

  # One edge removed per destination id, halting (and returning the error so Ash
  # rolls the vertex back) on the first failed or 0-row delete. The loop runs inside
  # the action transaction, so a mid-list halt rolls all prior removals back.
  defp destroy_all(conn, record, dest_ids, resource, edge, src_key, tenant) do
    Enum.reduce_while(dest_ids, {:ok, record}, fn dest_id, {:ok, rec} ->
      case destroy_one(conn, resource, edge, src_key, dest_id, tenant) do
        {:ok, _} -> {:cont, {:ok, rec}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp destroy_one(conn, resource, edge, src_key, dest_id, tenant) do
    {cypher, params} = build_destroy(resource, edge, src_key, dest_id, tenant)

    # Count-decode: [_|_] echoes `<deleted>` per removed edge (E3) → :ok; [] → the
    # WHERE matched nothing → StaleRecord (fail-closed). Never row_to_attrs the echo.
    case Arcadic.command(conn, cypher, params) do
      {:ok, [_ | _]} ->
        {:ok, :destroyed}

      {:ok, []} ->
        {:error, StaleRecord.exception(resource: resource, filter: redacted(src_key, dest_id))}

      {:error, error} ->
        {:error,
         InvalidRelationship.exception(
           relationship: edge.name,
           message: DataLayer.redact_db_error(error)
         )}
    end
  end

  @doc false
  # Pure builder — unit-tested. Sets no properties (a delete); RETURN column is `r`.
  # Scopes BOTH endpoints in the WHERE (via the SAME EdgeCypher source_where/tenant_where
  # as CreateEdge) so the delete's tenant/identifier clauses cannot diverge from the
  # create's.
  def build_destroy(resource, edge, src_key, dest_id, tenant) do
    src_label = EdgeCypher.validated_label(resource)
    dest_label = EdgeCypher.validated_label(edge.destination)
    edge_label = Identifier.validate!(edge.label)
    dest_pk = EdgeCypher.destination_pk!(edge.destination)

    {src_where, src_params} = EdgeCypher.source_where(src_key)
    {tenant_where, tenant_params} = EdgeCypher.tenant_where(tenant)

    pattern =
      case edge.direction do
        :incoming -> "(a:#{src_label})<-[r:#{edge_label}]-(b:#{dest_label})"
        _ -> "(a:#{src_label})-[r:#{edge_label}]->(b:#{dest_label})"
      end

    cypher =
      "MATCH #{pattern} WHERE #{src_where} AND b.#{dest_pk} = $dst#{tenant_where} DELETE r RETURN r"

    {cypher, src_params |> Map.put("dst", dest_id) |> Map.merge(tenant_params)}
  end

  # Rule-4: carry PK field NAMES only (values may be PII/ciphertext).
  defp redacted(src_key, _dest_id) do
    src_key |> Map.keys() |> Map.new(&{&1, "<redacted>"}) |> Map.put("dst", "<redacted>")
  end

  defp conn_reason(:tenant_required), do: "tenant required"
  defp conn_reason(:cross_database_transaction), do: "transaction spans multiple databases"
  defp conn_reason(:transaction_begin_failed), do: "could not begin ArcadeDB transaction"
end
