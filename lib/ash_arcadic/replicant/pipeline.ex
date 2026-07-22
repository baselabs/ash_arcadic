defmodule AshArcadic.Replicant.Pipeline do
  @moduledoc """
  A supervision-child helper that starts a `replicant` CDC pipeline for an
  `AshArcadic.ReplicantSink`, wiring `Replicant.start_link/1` with the **correct Ch3
  start-mode**: a `snapshot` bootstrap on an empty checkpoint, a resume otherwise.

      children = [
        {AshArcadic.Replicant.Pipeline,
         connection: [hostname: "standby.internal", port: 5432, username: "u",
                      password: "p", database: "evidence", ssl: true],
         publication: "evidence_pub",
         sink: MyGraph.ReplicantSink}
      ]

  The host supplies `:connection` and `:publication`; the `:sink` module carries the
  `slot_name` + `domains` + checkpoint (baked by `use AshArcadic.ReplicantSink`), which
  are the single source of truth for both the resolver index and the replication slot.

  ## Start-mode (Ch3) — why not `go_forward_only`

  `Replicant.Config` **refuses** an empty-checkpoint `:state_mirror` sink without
  `go_forward_only: true`, and `go_forward_only` seeds only from the slot's creation point
  — losing every pre-slot row, which breaks the rebuildable-projection premise. So
  `start_link/1` reads `sink.checkpoint()` and selects:

    * `{:ok, nil}` (never applied) → `snapshot: true` — bootstrap the FULL pre-existing
      state (`Replicant.Config`'s guard treats a snapshot intent as the safe empty-start
      seed).
    * anything else (`{:ok, integer}` durable watermark, OR a read fault) → `snapshot:
      false` — resume. A read fault is fail-open (the guard treats "unknown" as
      "not definitively empty"; a re-delivered already-applied txn is deduped by the
      idempotent sink), never a partial `go_forward_only` seed.

  It NEVER passes `go_forward_only`.

  ## Supervision

  `Replicant.start_link/1` starts the pipeline under `replicant`'s own supervisor as a
  `:temporary` child — a fail-closed halt (bad config, destructive schema change, sink
  failure) terminates it permanently, and transient crashes recover inside replicant's
  per-pipeline `:one_for_all`. This helper's `child_spec/1` is therefore `restart:
  :temporary` too: it starts the pipeline once at boot and must not auto-restart it (a
  restart would re-create a duplicate pipeline on the same slot, and a fail-closed halt
  must stay permanent). Replicant's supervisor owns the running pipeline's lifecycle; this
  child is the boot trigger. A bad config (`Impl.config/1` raise, or a
  `Replicant.start_link/1` `{:error, _}`) fails the host's boot loud (fail-closed).
  """

  alias AshArcadic.Replicant.Sink.Impl

  @doc """
  A supervision child spec. `opts` requires `:connection`, `:publication`, and `:sink`
  (a `use AshArcadic.ReplicantSink` module). The child id is keyed by the sink's slot so
  a host can run multiple pipelines. `:temporary` — see the moduledoc.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    sink = Keyword.fetch!(opts, :sink)
    %{slot: slot} = sink.__ash_arcadic_replicant_config__()

    %{
      id: {__MODULE__, slot},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @doc """
  Start the pipeline: force the resolver index build (fail-closed at start on a
  duplicate/missing source), then wire `Replicant.start_link/1` with the connection,
  publication, slot, sink, and the Ch3 start-mode. Returns `Replicant.start_link/1`'s
  `{:ok, pid} | {:error, reason}`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    sink = Keyword.fetch!(opts, :sink)
    connection = Keyword.fetch!(opts, :connection)
    publication = Keyword.fetch!(opts, :publication)
    %{slot: slot} = raw = sink.__ash_arcadic_replicant_config__()

    # Build (+ cache) the resolver index at START, fail-closed on a duplicate/missing
    # source, so a mis-mapped mirror fails the host's boot rather than silently starting
    # and dropping every change of the unmapped table.
    _ = Impl.config(raw)

    Replicant.start_link(
      [connection: connection, slot_name: slot, publication: publication, sink: sink] ++
        start_mode(sink)
    )
  end

  @doc """
  The Ch3 start-mode opts for `sink` — `[snapshot: true]` on an empty checkpoint (bootstrap
  the full state), `[snapshot: false]` otherwise (a durable watermark resumes; a checkpoint
  read fault is fail-open → resume, deduped on redelivery). NEVER `go_forward_only`.
  """
  @spec start_mode(module()) :: [snapshot: boolean()]
  def start_mode(sink) do
    case safe_checkpoint(sink) do
      {:ok, nil} -> [snapshot: true]
      _other -> [snapshot: false]
    end
  end

  # A checkpoint read fault is fail-open (mirrors `Replicant.Config`'s start guard) and
  # value-free — the reason is never inspected. Return a sentinel that is NOT {:ok, nil}, so
  # start_mode/1 resumes rather than re-bootstrapping on a transient read failure.
  defp safe_checkpoint(sink) do
    sink.checkpoint()
  rescue
    _ -> :read_fault
  catch
    _kind, _reason -> :read_fault
  end
end
