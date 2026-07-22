defmodule AshArcadic.ReplicantSinkTest do
  @moduledoc false
  # No-server unit tests for the `use AshArcadic.ReplicantSink` macro's config-free
  # callbacks (sink_kind / supports_snapshot? / checkpoint), the Pipeline's Ch3
  # start-mode selection, and the fail-closed config build. `checkpoint/0` reads the
  # baked `checkpoint_resource.for_slot(slot)` directly (no resolver index, no DB), so
  # a plain STUB checkpoint module suffices here — the live watermark round-trip is in
  # `CheckpointTest`, and `handle_transaction/1`'s live delegation is in the integration
  # module below. Full bootstrap is proven live in the T8 integration slice.
  use ExUnit.Case, async: true

  alias AshArcadic.Replicant.Error
  alias AshArcadic.Replicant.Pipeline
  alias AshArcadic.Replicant.Sink.Impl

  # A stub checkpoint (no DB): `checkpoint/0` calls `checkpoint_resource.for_slot(slot)`.
  defmodule StubCheckpoint do
    @moduledoc false
    def for_slot("sink-empty"), do: nil
    def for_slot("sink-full"), do: 42
  end

  defmodule EmptySink do
    @moduledoc false
    # domains: [] exercises only the config-FREE callbacks here (sink_kind / checkpoint /
    # supports_snapshot? / start_mode) — never handle_transaction/handle_snapshot, which
    # would build the (empty) resolver index.
    use AshArcadic.ReplicantSink,
      checkpoint_resource: StubCheckpoint,
      slot_name: "sink-empty",
      domains: []
  end

  defmodule FullSink do
    @moduledoc false
    use AshArcadic.ReplicantSink,
      checkpoint_resource: StubCheckpoint,
      slot_name: "sink-full",
      domains: []
  end

  # A minimal sink-shaped stub whose checkpoint/0 RAISES — the read-fault start-mode case.
  defmodule FaultSink do
    @moduledoc false
    def checkpoint, do: raise("checkpoint read fault")
  end

  # --- Two mirrors claiming the SAME {public, sink_dups} source: the duplicate-source
  # ambiguity `Resolver.build_index/1` fails closed on, which `Impl.config/1` must surface
  # as a raise (a duplicate/missing source must NOT silently start). Read-only, so the
  # write-action seam-lock verifier does not fire (no authorizer needed). ---
  defmodule Elixir.AshArcadic.Test.Replicant.SinkDupA do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.SinkDupDomain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant]

    arcade do
      client(AshArcadic.Test.MockClient)
    end

    replicant do
      source_table("sink_dups")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Elixir.AshArcadic.Test.Replicant.SinkDupB do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.SinkDupDomain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant]

    arcade do
      client(AshArcadic.Test.MockClient)
    end

    replicant do
      source_table("sink_dups")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Elixir.AshArcadic.Test.Replicant.SinkDupDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshArcadic.Test.Replicant.SinkDupA
      resource AshArcadic.Test.Replicant.SinkDupB
    end
  end

  describe "sink_kind/0" do
    test "is :state_mirror (the go-forward start guard depends on this)" do
      assert EmptySink.sink_kind() == :state_mirror
    end
  end

  describe "supports_snapshot?/1 — the config gate for snapshot: true" do
    test "true: BOTH snapshot callbacks are present (a partial impl is rejected :snapshot_unsupported)" do
      assert Replicant.Sink.supports_snapshot?(EmptySink)
    end
  end

  describe "checkpoint/0 — reads the durable watermark" do
    test "reads the integer watermark from the checkpoint resource" do
      assert FullSink.checkpoint() == {:ok, 42}
    end

    test "returns {:ok, nil} for a never-applied slot (the F1 empty case)" do
      assert EmptySink.checkpoint() == {:ok, nil}
    end
  end

  describe "Pipeline.start_mode/1 — Ch3: snapshot on empty, resume otherwise" do
    test "an EMPTY checkpoint ({:ok, nil}) selects snapshot: true (bootstrap the full state)" do
      assert Pipeline.start_mode(EmptySink) == [snapshot: true]
    end

    test "a NON-EMPTY checkpoint ({:ok, integer}) selects snapshot: false (resume)" do
      assert Pipeline.start_mode(FullSink) == [snapshot: false]
    end

    # A read fault means the checkpoint state is UNKNOWN — resuming forward-only on an actually
    # EMPTY checkpoint would skip the required snapshot bootstrap and PERMANENTLY omit every
    # pre-slot row (the exact Ch3 failure the snapshot prevents). So a read fault fails CLOSED:
    # the pipeline start halts value-free (a transient fault is an operator retry), never a
    # silent forward-only. RED against the previous `_other -> [snapshot: false]`.
    test "a checkpoint READ FAULT fails CLOSED (raises), never resumes forward-only (row-loss guard)" do
      assert_raise Error, fn -> Pipeline.start_mode(FaultSink) end
    end
  end

  describe "Impl.config/1 — fail-closed build (a duplicate/missing source must not silently start)" do
    test "raises value-free on a duplicate-source index build (never silently starts)" do
      slot = "sink-dup-#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn ->
        Impl.config(%{
          domains: [AshArcadic.Test.Replicant.SinkDupDomain],
          checkpoint: StubCheckpoint,
          slot: slot
        })
      end
    end
  end

  describe "Impl snapshot callbacks — a wholesale-empty index fails closed :empty_index" do
    # An empty resolver index (empty/wrong domains) would resolve every snapshot row to nil
    # (unmapped → :ok) and silently "complete" an empty mirror. The whole-index guard fires
    # BEFORE any write, value-free. This is distinct from a NON-empty index with one unmapped
    # table — a legitimate partial-publication skip (next test).
    test "handle_snapshot on a wholesale-empty index returns {:error, :empty_index}" do
      empty = %{
        resolver_index: %{},
        checkpoint: StubCheckpoint,
        slot: "snap-empty",
        authorize?: false
      }

      change = %Replicant.Change{
        op: :snapshot,
        schema: "public",
        table: "foo",
        record: %{"id" => "1"}
      }

      assert {:error, %Error{reason: :empty_index}} =
               Impl.handle_snapshot(empty, [change], %{
                 table: "public.foo",
                 first_for_table?: true
               })
    end

    test "handle_snapshot on a NON-empty index skips an unmapped table :ok (partial-publication preserved)" do
      # A non-empty index whose value is never dereferenced (the table is unmapped).
      nonempty = %{
        resolver_index: %{{"public", "mapped"} => __MODULE__},
        checkpoint: StubCheckpoint,
        slot: "snap-skip",
        authorize?: false
      }

      assert :ok =
               Impl.handle_snapshot(nonempty, [], %{
                 table: "public.unmapped",
                 first_for_table?: true
               })
    end

    test "handle_snapshot with a malformed non-binary context.table fails closed value-free (no raw raise)" do
      # Non-empty index so the empty-index guard passes; a non-binary table makes the pre-batch
      # split_qualified raise — which must route through the value-free boundary (symmetric with
      # apply_transaction/2), never escape as a raw uncaught error.
      nonempty = %{
        resolver_index: %{{"public", "mapped"} => __MODULE__},
        checkpoint: StubCheckpoint,
        slot: "snap-malformed",
        authorize?: false
      }

      assert {:error, %Error{reason: :sink_failed}} =
               Impl.handle_snapshot(nonempty, [], %{table: 123, first_for_table?: true})
    end
  end
end

defmodule AshArcadic.ReplicantSinkIntegrationTest do
  @moduledoc false
  # Live-ArcadeDB proof that the `use AshArcadic.ReplicantSink` macro wires
  # `handle_transaction/1` to `AshArcadic.Replicant.Apply` — the row lands and the
  # watermark advances through the generated callback (Apply's observable effect). The
  # full effect-once / replay / crash / snapshot matrix is the T8 integration slice.
  use AshArcadic.Test.IntegrationCase

  defmodule Elixir.AshArcadic.Test.Replicant.SinkOrder do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.SinkDelegationDomain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant],
      authorizers: [Ash.Policy.Authorizer]

    arcade do
      client(AshArcadic.Test.IntegrationClient)
      label(:SinkDelegationOrder)
    end

    replicant do
      source_table("sink_orders")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :note, :string, public?: true
    end

    actions do
      default_accept [:id, :note]
      defaults [:read, :create, :update, :destroy]
    end

    policies do
      policy always() do
        forbid_if always()
      end
    end
  end

  defmodule Elixir.AshArcadic.Test.Replicant.SinkDelegationDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshArcadic.Test.Replicant.SinkOrder
    end
  end

  defmodule Checkpoint do
    @moduledoc false
    use AshArcadic.ReplicantCheckpoint,
      domain: AshArcadic.Test.Domain,
      client: AshArcadic.Test.IntegrationClient
  end

  defmodule Sink do
    @moduledoc false
    use AshArcadic.ReplicantSink,
      checkpoint_resource: Checkpoint,
      slot_name: "sink-delegation",
      domains: [AshArcadic.Test.Replicant.SinkDelegationDomain]
  end

  # A mis-configured sink: NO mapped resources (empty/wrong domains). Every change would be
  # silently dropped while the checkpoint advances — the empty-index guard must fail closed.
  defmodule EmptyDomainsSink do
    @moduledoc false
    use AshArcadic.ReplicantSink,
      checkpoint_resource: Checkpoint,
      slot_name: "sink-empty-domains",
      domains: []
  end

  setup do
    on_exit(fn ->
      AshArcadic.Transaction.clear()
      :persistent_term.erase({AshArcadic.Replicant.Sink.Impl, "sink-delegation"})
      :persistent_term.erase({AshArcadic.Replicant.Sink.Impl, "sink-empty-domains"})
    end)

    :ok
  end

  defp change(op, table, record, old_record \\ nil) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: table,
      record: record,
      old_record: old_record
    }
  end

  defp txn(lsn, changes), do: %Replicant.Transaction{commit_lsn: lsn, changes: changes}

  alias AshArcadic.Replicant.Error
  alias AshArcadic.Test.Replicant.SinkOrder

  test "handle_transaction/1 delegates to Apply: applies the change and advances the watermark" do
    assert Sink.checkpoint() == {:ok, nil}

    assert {:ok, 5} =
             Sink.handle_transaction(
               txn(5, [change(:insert, "sink_orders", %{"id" => "s1", "note" => "hi"})])
             )

    assert %SinkOrder{note: "hi"} = Ash.get!(SinkOrder, "s1", authorize?: false)
    assert Sink.checkpoint() == {:ok, 5}
  end

  test "an empty-domains sink fails closed :empty_index (no invisible loss; checkpoint not advanced)" do
    assert EmptyDomainsSink.checkpoint() == {:ok, nil}

    assert {:error, %Error{reason: :empty_index}} =
             EmptyDomainsSink.handle_transaction(
               txn(9, [change(:insert, "sink_orders", %{"id" => "leak", "note" => "no"})])
             )

    assert {:error, %Error{reason: :empty_index}} =
             EmptyDomainsSink.handle_snapshot_complete(9)

    # loss=0: neither delivery path advanced the checkpoint.
    assert EmptyDomainsSink.checkpoint() == {:ok, nil}
  end
end
