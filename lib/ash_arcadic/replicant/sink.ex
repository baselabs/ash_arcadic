defmodule AshArcadic.ReplicantSink do
  @moduledoc """
  `use AshArcadic.ReplicantSink, domains: [...], checkpoint_resource: MyGraph.Checkpoint,
  slot_name: "sirtify_graph"` generates a `Replicant.Sink` implementation bound to a
  host's config — the Postgres→ArcadeDB effect-once CDC mirror's delivery seam.

  The generated module implements (`../replicant/lib/replicant/sink.ex` — the behaviour):

    * `checkpoint/0` → `{:ok, checkpoint_resource.for_slot(slot_name)}` — the durable
      integer watermark, or `nil` (never applied). Reads the baked checkpoint resource
      directly (no resolver index), so it is cheap and safe to call at pipeline start
      for the Ch3 start-mode decision.
    * `handle_transaction/1` → delegates to `AshArcadic.Replicant.Apply.apply_transaction/2`
      (the effect-once core: one `Ash.transaction` co-committing the mirrored writes and
      the watermark advance).
    * `sink_kind/0` → `:state_mirror`. The graph is a rebuildable projection; this gates
      `Replicant.Config`'s go-forward start guard (an empty-checkpoint `:state_mirror`
      is refused without `go_forward_only: true` OR a snapshot — see the Pipeline).
    * `handle_snapshot/2` + `handle_snapshot_complete/1` → the Ch3 bootstrap (both
      required, so `Replicant.Sink.supports_snapshot?/1` is true and `snapshot: true` is
      accepted; a partial impl is rejected `:snapshot_unsupported`). Delegated to
      `AshArcadic.Replicant.Sink.Impl` — see there for the `first_for_table?`
      redo-safety semantics.

  ## Config (`__config__/0`)

  The `Replicant.Sink` callbacks carry no pipeline context, so the config is baked into
  the generated module: `domains`, `checkpoint_resource`, `slot_name`. The
  `AshArcadic.Replicant.Apply.config` map (`resolver_index` + `checkpoint` + `slot` +
  `authorize?: false`) is assembled by `AshArcadic.Replicant.Sink.Impl.config/1`, which
  builds the resolver index ONCE (cached in `:persistent_term` keyed by slot) and **fails
  closed at build time** on a duplicate/missing `source_table` — a mis-mapped mirror must
  not silently start.

  ## `optional: true` compile note

  `replicant` is an `optional: true` dep. `AshArcadic.Replicant.Apply` / `Sink.Impl` /
  `Pipeline` reference `%Replicant.Transaction{}` / `%Replicant.Change{}` structs and
  `Replicant.start_link/1` (hard compile-time dependencies), so those three modules are
  **compile-gated** on `if Code.ensure_loaded?(Replicant.Sink)` — a non-CDC host builds
  ash_arcadic without `replicant` and that subtree simply compiles away. A host that uses
  the CDC sink adds `{:replicant, "~> 0.3"}` to its own deps; `use AshArcadic.ReplicantSink`
  requires it (its `@behaviour Replicant.Sink` / delegation to `Apply` bind at the host's
  compile). If a host adds `replicant` AFTER an initial non-CDC compile, run
  `mix deps.compile ash_arcadic --force` so the gated subtree recompiles.
  """

  # Aliased at the macro-module level so the SHORT names resolve inside the `quote`
  # (Elixir expands aliases using this module's alias table, so the generated consumer
  # code is correctly fully-qualified without the consumer needing its own alias).
  alias AshArcadic.Replicant.Apply
  alias AshArcadic.Replicant.Sink.Impl

  @doc false
  defmacro __using__(opts) do
    domains = Keyword.fetch!(opts, :domains)
    checkpoint_resource = Keyword.fetch!(opts, :checkpoint_resource)
    slot_name = Keyword.fetch!(opts, :slot_name)

    quote do
      @behaviour Replicant.Sink

      @doc false
      # The baked, index-free config the Pipeline reads (domains + slot for the resolver
      # index build; checkpoint for the Apply config). Mirrors the precedent's
      # `__ash_replicant_config__/0`.
      @spec __ash_arcadic_replicant_config__() :: %{
              domains: [module()],
              checkpoint: module(),
              slot: String.t()
            }
      def __ash_arcadic_replicant_config__ do
        %{
          domains: unquote(domains),
          checkpoint: unquote(checkpoint_resource),
          slot: unquote(slot_name)
        }
      end

      # The full `AshArcadic.Replicant.Apply.config` map (resolver_index built once +
      # cached; authorize?: false). Fails closed at build time on a duplicate/missing
      # source (`Impl.config/1`).
      defp __config__, do: Impl.config(__ash_arcadic_replicant_config__())

      @impl Replicant.Sink
      def checkpoint, do: {:ok, unquote(checkpoint_resource).for_slot(unquote(slot_name))}

      @impl Replicant.Sink
      def handle_transaction(txn), do: Apply.apply_transaction(__config__(), txn)

      @impl Replicant.Sink
      def sink_kind, do: :state_mirror

      @impl Replicant.Sink
      def handle_snapshot(changes, context),
        do: Impl.handle_snapshot(__config__(), changes, context)

      @impl Replicant.Sink
      def handle_snapshot_complete(snapshot_lsn),
        do: Impl.handle_snapshot_complete(__config__(), snapshot_lsn)

      defoverridable checkpoint: 0,
                     handle_transaction: 1,
                     sink_kind: 0,
                     handle_snapshot: 2,
                     handle_snapshot_complete: 1
    end
  end
end
