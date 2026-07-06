defmodule AshArcadic.Telemetry do
  @moduledoc false
  # Value-free span wrapper for AshArcadic data-layer operations. Owns the
  # metadata allowlist — the single enforcement point for "no row-level or
  # tenant-derived value in telemetry" (AGENTS.md Rule 4). An off-allowlist key
  # (e.g. a tenant-derived `database`) fails loudly here rather than shipping
  # tenant identity into span metadata. `rls?` is dropped (no ArcadeDB RLS);
  # `in_transaction?` is added.

  @allowed_meta_keys ~w(resource multitenancy tenant? stale? in_transaction?
                        properties? direction row_count batch_size group_count
                        destination_count depth result kinds aggregate_count
                        traversal_aggregate? aggregate_kinds)a

  @spec allowed_meta_keys() :: [atom()]
  def allowed_meta_keys, do: @allowed_meta_keys

  @spec span(atom(), map(), (-> {term(), map()})) :: term()
  def span(op, start_meta, fun) when is_atom(op) and is_map(start_meta) and is_function(fun, 0) do
    :telemetry.span([:ash_arcadic, op], validate!(start_meta), fn ->
      {result, stop_meta} = fun.()
      {result, validate!(Map.merge(start_meta, stop_meta))}
    end)
  end

  @spec result_tag(term()) :: :ok | :error
  def result_tag({:error, _}), do: :error
  def result_tag(_), do: :ok

  @doc false
  def validate!(meta) when is_map(meta) do
    case Map.keys(meta) -- @allowed_meta_keys do
      [] ->
        meta

      bad ->
        raise ArgumentError,
              "telemetry metadata keys #{inspect(bad)} are not in the value-free allowlist " <>
                "#{inspect(@allowed_meta_keys)} (no row-level or tenant-derived value)"
    end
  end
end
