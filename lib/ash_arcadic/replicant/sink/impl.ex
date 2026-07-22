defmodule AshArcadic.Replicant.Sink.Impl do
  @moduledoc """
  The config-parameterized implementation the `use AshArcadic.ReplicantSink` macro
  delegates to: the `Replicant.Sink` config assembly plus the Ch3 snapshot bootstrap
  (`handle_snapshot/3` + `handle_snapshot_complete/2`). `checkpoint/0` and
  `handle_transaction/1` are thin enough to live in the macro (the former reads the
  baked checkpoint resource; the latter is a one-line delegate to
  `AshArcadic.Replicant.Apply.apply_transaction/2`).

  ## Config (`config/1`)

  Builds the `AshArcadic.Replicant.Apply.config` map. The `{schema, table} => resource`
  resolver index is built ONCE from the sink's `domains` and cached in `:persistent_term`
  keyed by slot (like the `ash_replicant` precedent), so it is not rebuilt per transaction.
  **Fails closed at build time** on a duplicate/missing `source_table`
  (`Resolver.build_index/1`'s error tuple): a mis-mapped mirror must not silently start.
  The raised error is value-free (a duplicate/missing `source_table` is a config
  identifier, never a source row value).

  ## Snapshot bootstrap (Ch3) — `first_for_table?` redo-safety and its semantics

  An empty-checkpoint start (`checkpoint/0 == {:ok, nil}`) is bootstrapped by a v1
  snapshot: `replicant` `EXPORT_SNAPSHOT` → `COPY` → hands each source row to
  `handle_snapshot/3` as a `%Replicant.Change{op: :snapshot}`, then calls
  `handle_snapshot_complete/2` once. Each snapshot row is materialized by REUSING the
  live-stream upsert path — `AshArcadic.Replicant.Apply.apply_change/2` with the op
  rewritten to `:insert` — so `attrs_for_upsert`, `resolve_tenant!`, the empty-identity
  guard, and the sensitive-plaintext guard all apply byte-identically. The checkpoint is
  NOT advanced here; it stays `nil` (`handle_snapshot_complete/2` sets it) so a crash
  mid-snapshot re-runs the WHOLE snapshot.

  **`first_for_table?` clearing — decision: blanket clear + checkpoint convergence.**
  On the first batch per table `handle_snapshot/3` clears the table's prior mirror rows
  (a tenant-blind whole-label `MATCH (n:Label) DETACH DELETE n`, atomic with the batch's
  upserts in one `Ash.transaction` session), so a redo (the snapshot re-runs on any
  failure) never leaves a stale row the source deleted between attempts. This sink
  implements **only** replicant's v1 snapshot (it does NOT export `snapshot_progress/0`,
  so `Replicant.Config` never runs it in incremental mode). Under v1 the snapshot is a
  distinct phase BEFORE the live stream starts (COPY → then `START_REPLICATION` at the
  consistent point), so there are no `handle_transaction/1`-applied rows to preserve when
  the clear runs — the blanket clear cannot lose a stream row. Even in a hypothetical
  interleave, the checkpoint stays `nil` until `handle_snapshot_complete/2`, so the stream
  resumes from `snapshot_lsn` and any post-snapshot change a blanket clear removed
  (`lsn > snapshot_lsn`) is RE-DELIVERED → the `:state_mirror` converges (eventual
  consistency for a rebuildable projection; design §1.6 permits a documented approach).
  No stream row is ever permanently lost. **If this sink ever adopts replicant's
  incremental snapshot** (`snapshot: [mode: :incremental]`, which interleaves chunks with
  the live stream and requires `snapshot_progress/0`), this blanket clear MUST change to
  clear only snapshot-origin rows (origin-tracking) — otherwise a stream update that lands
  before the first chunk closes is lost (replicant incremental "Bug C").

  ## Value-free error boundary

  `handle_snapshot/3` and `handle_snapshot_complete/2` return `:ok` / `{:ok, lsn}` or a
  VALUE-FREE `{:error, _}` — a batch failure (a per-row raise scrubbed by `apply_change`,
  a clear failure, or a data-layer rollback that returns a value-bearing `Ash.Error`
  container) is routed through `boundary_error/1`, which mirrors
  `AshArcadic.Replicant.Apply`'s boundary: only a bare `AshArcadic.Replicant.Error` or a
  structural `AshArcadic.Errors.*` crosses; any value-bearing or unrecognized term maps to
  a static `:sink_failed` (`project_redaction_fail_path_exception_leak` — a new wire
  surface gates value-free, diffed against its sibling).
  """

  alias AshArcadic.DataLayer.Info, as: DataLayerInfo
  alias AshArcadic.Replicant.Apply
  alias AshArcadic.Replicant.Error
  alias AshArcadic.Replicant.Resolver

  @index_prefix __MODULE__

  @doc """
  Assemble the `AshArcadic.Replicant.Apply.config` map from the sink's baked
  `%{domains:, checkpoint:, slot:}`. Builds the resolver index once (cached in
  `:persistent_term` keyed by slot); raises value-free on a build_index error tuple
  (a duplicate/missing `source_table` must not silently start).
  """
  @spec config(%{domains: [module()], checkpoint: module(), slot: String.t()}) :: Apply.config()
  def config(%{domains: domains, checkpoint: checkpoint, slot: slot}) do
    %{
      resolver_index: resolver_index(slot, domains),
      checkpoint: checkpoint,
      slot: slot,
      authorize?: false
    }
  end

  defp resolver_index(slot, domains) do
    key = {@index_prefix, slot}

    case :persistent_term.get(key, :undefined) do
      :undefined ->
        index = build_index!(domains)
        :persistent_term.put(key, index)
        index

      index ->
        index
    end
  end

  # Fail closed at build time: a duplicate or missing source_table is a config error the
  # sink must not silently start past. The reason is NOT interpolated — a `{schema, table}`
  # source key / resource module is a config identifier, but the boundary stays value-free
  # by construction (a static message), never rendering a row.
  defp build_index!(domains) do
    case Resolver.build_index(domains) do
      {:ok, index} ->
        index

      {:error, _reason} ->
        raise ArgumentError,
              "ash_arcadic replicant: resolver index build failed (a duplicate or missing " <>
                "source_table in the sink's domains) — the sink must not start"
    end
  end

  @doc """
  Persist one snapshot batch for `context.table`, upserting each row by PK (Ch3). On
  `context.first_for_table?` the table's prior mirror rows are cleared first, atomic with
  the batch (see the moduledoc for the blanket-clear-with-convergence semantics). An
  unmapped table is a legitimate partial-publication skip (`:ok`). Does NOT advance the
  checkpoint. Returns `:ok` or a value-free `{:error, _}`.
  """
  @spec handle_snapshot(Apply.config(), [Replicant.Change.t()], map()) :: :ok | {:error, term()}
  def handle_snapshot(config, changes, %{table: qualified, first_for_table?: first?}) do
    {schema, table} = split_qualified(qualified)

    case Resolver.lookup(config.resolver_index, schema, table) do
      nil -> :ok
      resource -> run_snapshot_batch(config, resource, changes, first?)
    end
  end

  # ONE session (Ch1): the first_for_table? clear + every row upsert commit atomically, so
  # a redo never observes a half-cleared / half-loaded table. `[resource]` is non-empty, so
  # `Ash.transaction/2` engages the data-layer session. Route every failure — returned
  # rollback, raise, or throw/exit — through the value-free boundary.
  defp run_snapshot_batch(config, resource, changes, first?) do
    case Ash.transaction([resource], fn ->
           apply_snapshot_batch(config, resource, changes, first?)
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, boundary_error(reason)}
    end
  rescue
    exception -> {:error, boundary_error(exception)}
  catch
    kind, value when kind in [:throw, :exit] -> {:error, boundary_error(value)}
  end

  # The batch body, inside the enclosing snapshot session: clear the table on the first
  # batch (redo-safety), then upsert each row via the reused live-stream :insert path.
  defp apply_snapshot_batch(config, resource, changes, first?) do
    if first?, do: clear_label!(resource)
    Enum.each(changes, fn change -> Apply.apply_change(config, snapshot_insert(change)) end)
  end

  @doc """
  The snapshot handoff commit (Ch3): durably set `checkpoint := snapshot_lsn` and return
  it. Until this succeeds the checkpoint stays `nil`, so a crash before it re-runs the
  whole snapshot. Returns `{:ok, snapshot_lsn}` or a value-free `{:error, _}`.
  """
  @spec handle_snapshot_complete(Apply.config(), Replicant.lsn()) ::
          {:ok, Replicant.lsn()} | {:error, term()}
  def handle_snapshot_complete(config, snapshot_lsn) do
    case Ash.transaction([config.checkpoint], fn ->
           config.checkpoint.upsert_lsn(config.slot, snapshot_lsn)
         end) do
      {:ok, _} -> {:ok, snapshot_lsn}
      {:error, reason} -> {:error, boundary_error(reason)}
    end
  rescue
    exception -> {:error, boundary_error(exception)}
  catch
    kind, value when kind in [:throw, :exit] -> {:error, boundary_error(value)}
  end

  # A snapshot row arrives as %Change{op: :snapshot}; the apply invariant map upserts on
  # :insert (MERGE by PK). Rewrite the op via a MAP update so the whole T5 upsert path
  # (attrs_for_upsert / resolve_tenant! / empty-identity + sensitive guards) is reused
  # byte-identically. `Apply.apply_change/2` raises value-free on any failure, rolling the
  # batch back.
  defp snapshot_insert(change), do: %{change | op: :insert}

  # Redo-safety clear: a tenant-blind whole-label DELETE (a Postgres source is tenant-blind;
  # a tenant-scoped destroy would need a tenant the snapshot lacks). Deliberately mirrors
  # `AshArcadic.Replicant.Apply`'s truncate `:mirror` mechanism, sharing the public
  # data-layer entry point `base_write_conn/1`: the label is allowlist-validated (Rule 1 —
  # never a `$param`), and the raw command runs IN the enclosing snapshot session so the
  # clear is atomic with the batch's upserts. Value-free on failure.
  defp clear_label!(resource) do
    label = resource |> DataLayerInfo.label() |> AshArcadic.Identifier.validate!()

    case AshArcadic.DataLayer.base_write_conn(resource) do
      {:ok, conn} ->
        case Arcadic.command(conn, "MATCH (n:#{label}) DETACH DELETE n", %{}) do
          {:ok, _rows} ->
            :ok

          {:error, _error} ->
            raise Error.exception(reason: :sink_failed, resource: resource, op: :snapshot)
        end

      {:error, _reason} ->
        raise Error.exception(reason: :sink_failed, resource: resource, op: :snapshot)
    end
  end

  # `context.table` is `"schema.table"` or a bare `"table"`; apply the SAME nil-schema →
  # "public" default `Resolver.lookup/3` / the index keys use.
  defp split_qualified(qualified) do
    case String.split(qualified, ".", parts: 2) do
      [schema, table] -> {schema, table}
      [table] -> {"public", table}
    end
  end

  # The value-free boundary, mirroring `AshArcadic.Replicant.Apply.boundary_error/1` (the
  # sibling wire surface): only our own `AshArcadic.Replicant.Error` (atoms only) or a bare
  # structural `AshArcadic.Errors.*` data-layer error (value-free by AGENTS.md Rule 4)
  # crosses. A value-bearing `Ash.Error` CONTAINER (carrying the changeset/source row) never
  # crosses — if it wraps only bare value-free errors, surface the first; otherwise, and for
  # ANY unrecognized term, fail closed to a static `:sink_failed`.
  defp boundary_error(%Error{} = error), do: error
  defp boundary_error(%AshArcadic.Errors.CreateFailed{} = error), do: error
  defp boundary_error(%AshArcadic.Errors.UpdateFailed{} = error), do: error
  defp boundary_error(%AshArcadic.Errors.QueryFailed{} = error), do: error
  defp boundary_error(%AshArcadic.Errors.UnsupportedFilter{} = error), do: error

  defp boundary_error(%{errors: [_ | _] = errors}) do
    if Enum.all?(errors, &data_layer_value_free?/1), do: hd(errors), else: sink_failed()
  end

  defp boundary_error(_other), do: sink_failed()

  defp data_layer_value_free?(%AshArcadic.Errors.CreateFailed{}), do: true
  defp data_layer_value_free?(%AshArcadic.Errors.UpdateFailed{}), do: true
  defp data_layer_value_free?(%AshArcadic.Errors.QueryFailed{}), do: true
  defp data_layer_value_free?(%AshArcadic.Errors.UnsupportedFilter{}), do: true
  defp data_layer_value_free?(_other), do: false

  defp sink_failed, do: Error.exception(reason: :sink_failed, op: :snapshot)
end
