defmodule AshArcadic.Replicant.ApplyUnitTest do
  @moduledoc false
  # No-server unit tests for the fail-closed dispatch + the F1 replay gate + the Ch1
  # atomicity mechanism. Every guard here fires BEFORE any DB touch (or is pure), so the
  # MockClient-backed resources never open a session — the live per-op effects + crash
  # atomicity are proven in ApplyIntegrationTest / the sink's integration slice.
  use ExUnit.Case, async: true

  alias AshArcadic.Replicant.Apply
  alias AshArcadic.Replicant.Error

  defmodule Thing do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant],
      authorizers: [Ash.Policy.Authorizer]

    arcade do
      client(AshArcadic.Test.MockClient)
      label(:ApplyUnitThing)
    end

    replicant do
      source_table("things")
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

  # A read-only mirror (no primary create/destroy action). A real mirror MUST be writable; the
  # apply path must fail closed value-free rather than raise a raw `primary_action!` error.
  defmodule ReadOnlyThing do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant]

    arcade do
      client(AshArcadic.Test.MockClient)
      label(:ApplyReadOnlyThing)
    end

    replicant do
      source_table("readonly_things")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Checkpoint do
    @moduledoc false
    use AshArcadic.ReplicantCheckpoint,
      domain: AshArcadic.Test.Domain,
      client: AshArcadic.Test.MockClient
  end

  setup do
    on_exit(fn -> AshArcadic.Transaction.clear() end)

    index = %{{"public", "things"} => Thing}

    %{
      config: %{
        resolver_index: index,
        checkpoint: Checkpoint,
        slot: "unit-slot",
        authorize?: false
      }
    }
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

  describe "replay_skip?/2 — the F1 replay gate (nil applies, integer compares)" do
    # F1 TRIPWIRE (mandatory, non-vacuous): a nil (never-applied) checkpoint APPLIES, it does
    # NOT skip. Red against a guardless `lsn <= stored` — in Erlang term order a number sorts
    # before every atom, so `5 <= nil` is TRUE and the guardless gate would wrongly skip.
    test "F1: a nil (never-applied) checkpoint APPLIES (does not skip)" do
      refute Apply.replay_skip?(nil, 5)
      refute Apply.replay_skip?(nil, 0)
    end

    test "an integer watermark >= lsn SKIPS (replay); < lsn APPLIES" do
      assert Apply.replay_skip?(10, 5)
      assert Apply.replay_skip?(10, 10)
      refute Apply.replay_skip?(10, 15)
    end
  end

  describe "resources/1 — Ch1: the data-layer-engaging resource set" do
    test "is non-empty and includes the mirror resources + the checkpoint", %{config: config} do
      resources = Apply.resources(config)

      assert Thing in resources
      assert Checkpoint in resources
      refute resources == []
    end

    test "dedups a resolver_index that maps two source tables to one resource" do
      config = %{
        resolver_index: %{{"public", "a"} => Thing, {"public", "b"} => Thing},
        checkpoint: Checkpoint,
        slot: "s",
        authorize?: false
      }

      assert Apply.resources(config) == [Thing, Checkpoint]
    end
  end

  describe "Ch1: a non-empty resources list engages the data-layer session" do
    # Proven BY EXECUTION (not by reading): inside `Ash.transaction([resource], fn)` the
    # process marker is SET, so the first write would open one shared session (effect-once).
    # With an EMPTY list Ash returns {:ok, fun.()} WITHOUT engaging the data layer — no
    # marker, no session — which is exactly why apply_transaction/2 must pass a non-empty list.
    test "marker is TRUE inside a non-empty-resources transaction, FALSE inside an empty one" do
      assert {:ok, true} =
               Ash.transaction([Thing], fn -> AshArcadic.Transaction.in_transaction?() end)

      assert {:ok, false} =
               Ash.transaction([], fn -> AshArcadic.Transaction.in_transaction?() end)
    end
  end

  describe "apply_change/2 fail-closed guards (fire before any DB touch)" do
    test "an unmapped {schema, table} is ignored (:ok)", %{config: config} do
      assert :ok = Apply.apply_change(config, change(:insert, "not_mirrored", %{"id" => "1"}))
    end

    test "a delete whose old_record lacks the PK fails closed value-free (no silent lost delete)",
         %{config: config} do
      err =
        assert_raise Error, fn ->
          Apply.apply_change(config, change(:delete, "things", nil, %{"note" => "no pk here"}))
        end

      assert err.reason == :missing_primary_key
      refute Exception.message(err) =~ "no pk here"
    end

    test "an upsert whose record lacks the PK REJECTS value-free (empty identity)", %{
      config: config
    } do
      err =
        assert_raise Error, fn ->
          Apply.apply_change(config, change(:insert, "things", %{"note" => "orphan"}))
        end

      assert err.reason == :empty_identity
      refute Exception.message(err) =~ "orphan"
    end

    test "a truncate with on_truncate :halt (default) fails closed value-free", %{config: config} do
      err =
        assert_raise Error, fn ->
          Apply.apply_change(config, change(:truncate, "things", nil))
        end

      assert err.reason == :truncate_halt
    end

    test "an op the invariant map does not cover fails closed value-free (never a leak)", %{
      config: config
    } do
      err =
        assert_raise Error, fn ->
          Apply.apply_change(
            config,
            change(:snapshot, "things", %{"id" => "1", "secret" => "leak"})
          )
        end

      assert err.reason == :unsupported_op
      refute Exception.message(err) =~ "leak"
    end

    # A read-only mirror (no primary create action) reaches the upsert path, which routes the
    # MERGE through `Ash.Resource.Info.primary_action!/2`. A real mirror MUST be writable — the
    # apply must fail closed with a SELF-DESCRIBING `:missing_mirror_action` (never a raw
    # `primary_action!` error). RED against the previous `create_action/1` = `primary_action!`:
    # the raw error is scrubbed to the generic `:sink_failed`, not the specific reason.
    test "an upsert to a mirror with no primary create action fails closed value-free (:missing_mirror_action)" do
      cfg = %{
        resolver_index: %{{"public", "readonly_things"} => ReadOnlyThing},
        checkpoint: Checkpoint,
        slot: "unit-readonly",
        authorize?: false
      }

      err =
        assert_raise Error, fn ->
          Apply.apply_change(cfg, change(:insert, "readonly_things", %{"id" => "1"}))
        end

      assert err.reason == :missing_mirror_action
    end
  end

  describe "emit_and_return/4 — :apply/:skip telemetry is emitted POST-commit (F2)" do
    # The telemetry emission moved OUT of the transaction body (`run/1`) into
    # `emit_and_return/4`, which runs on the RESULT of `Ash.transaction/2` — i.e. AFTER the
    # commit. So a commit failure (`{:error, :transaction_commit_failed}`, e.g. an MVCC
    # ConcurrentModificationException) that rolls the data back emits NO false `:apply`.
    # (A live commit failure can't be forced deterministically in this harness — StubTransport
    # cannot perform `run/1`'s real writes — so the gate is proven at this seam.)
    @apply_event [:ash_arcadic, :replicant, :transaction, :apply]
    @skip_event [:ash_arcadic, :replicant, :transaction, :skip]

    test "a committed apply outcome emits :apply and returns {:ok, lsn}" do
      ref = :telemetry_test.attach_event_handlers(self(), [@apply_event, @skip_event])

      assert {:ok, 9} = Apply.emit_and_return({:ok, {:applied, 2}}, "slot", 9, 100)

      assert_received {@apply_event, ^ref, %{change_count: 2}, %{slot: "slot", commit_lsn: 9}}
      refute_received {@skip_event, ^ref, _measurements, _meta}
      :telemetry.detach(ref)
    end

    test "a committed skip outcome emits :skip (with the incoming lsn) and returns {:ok, stored}" do
      ref = :telemetry_test.attach_event_handlers(self(), [@apply_event, @skip_event])

      assert {:ok, 10} = Apply.emit_and_return({:ok, {:skipped, 10}}, "slot", 9, 100)

      assert_received {@skip_event, ^ref, _measurements, %{slot: "slot", commit_lsn: 9}}
      refute_received {@apply_event, ^ref, _measurements, _meta}
      :telemetry.detach(ref)
    end

    test "a COMMIT FAILURE ({:error, :transaction_commit_failed}) emits NO event and fails closed value-free" do
      ref = :telemetry_test.attach_event_handlers(self(), [@apply_event, @skip_event])

      assert {:error, %Error{}} =
               Apply.emit_and_return({:error, :transaction_commit_failed}, "slot", 9, 100)

      refute_received {@apply_event, ^ref, _measurements, _meta}
      refute_received {@skip_event, ^ref, _measurements, _meta}
      :telemetry.detach(ref)
    end
  end
end

defmodule AshArcadic.Replicant.ApplyIntegrationTest do
  @moduledoc false
  # Live per-change effects + the truncate :mirror path + the F1 gate end-to-end, against a
  # throwaway ArcadeDB. Crash-atomicity itself is proven in the sink's integration slice.
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Replicant.Apply

  defmodule Order do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant],
      authorizers: [Ash.Policy.Authorizer]

    arcade do
      client(AshArcadic.Test.IntegrationClient)
      label(:ApplyOrder)
    end

    replicant do
      source_table("orders")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :note, :string, public?: true
      attribute :body, :string, public?: true
    end

    actions do
      default_accept [:id, :note, :body]
      defaults [:read, :create, :update, :destroy]
    end

    policies do
      policy always() do
        forbid_if always()
      end
    end
  end

  defmodule TenantThing do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant],
      authorizers: [Ash.Policy.Authorizer]

    arcade do
      client(AshArcadic.Test.IntegrationClient)
      label(:ApplyTenantThing)
    end

    replicant do
      source_table("tenant_things")
      tenant_attribute(:org_id)
      on_truncate(:mirror)
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :org_id, :string, allow_nil?: false, public?: true
      attribute :note, :string, public?: true
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      default_accept [:id, :org_id, :note]
      defaults [:read, :create, :update, :destroy]
    end

    policies do
      policy always() do
        forbid_if always()
      end
    end
  end

  defmodule Checkpoint do
    @moduledoc false
    use AshArcadic.ReplicantCheckpoint,
      domain: AshArcadic.Test.Domain,
      client: AshArcadic.Test.IntegrationClient
  end

  # A lazy, SINGLE-PASS Enumerable modelling replicant's `Replicant.Spill.Reader` — a
  # SPILLED (large) transaction's `changes` (Transaction.changes :: Enumerable.t()). It is
  # NOT a proper list, so `length/1` raises `ArgumentError`, and it is valid for exactly ONE
  # reduction (a second enumeration raises). So `run/1` must COUNT during its single `Enum`
  # pass — never `length(changes)`/`Enum.count(changes)`, which the previous code did after
  # `Enum.each` had already consumed the reader.
  defmodule OneShotChanges do
    @moduledoc false
    defstruct [:agent]

    def wrap(list) when is_list(list) do
      {:ok, agent} = Agent.start_link(fn -> {:fresh, list} end)
      %__MODULE__{agent: agent}
    end

    defimpl Enumerable do
      def count(_), do: {:error, __MODULE__}
      def member?(_, _), do: {:error, __MODULE__}
      def slice(_), do: {:error, __MODULE__}

      def reduce(%{agent: agent}, acc, fun) do
        case Agent.get_and_update(agent, fn state -> {state, :consumed} end) do
          {:fresh, list} -> Enumerable.reduce(list, acc, fun)
          :consumed -> raise "single-pass Enumerable already consumed"
        end
      end
    end
  end

  defp config(slot) do
    %{
      resolver_index: %{
        {"public", "orders"} => Order,
        {"public", "tenant_things"} => TenantThing
      },
      checkpoint: Checkpoint,
      slot: slot,
      authorize?: false
    }
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

  describe "per-change dispatch (live)" do
    test "insert then update UPSERTs by PK; a changed column is set, PK unchanged" do
      cfg = config("apply-upsert")

      assert {:ok, 1} =
               Apply.apply_transaction(
                 cfg,
                 txn(1, [change(:insert, "orders", %{"id" => "o1", "note" => "a"})])
               )

      assert %Order{note: "a"} = Ash.get!(Order, "o1", authorize?: false)

      assert {:ok, 2} =
               Apply.apply_transaction(
                 cfg,
                 txn(2, [
                   change(:update, "orders", %{"id" => "o1", "note" => "b"}, %{"id" => "o1"})
                 ])
               )

      assert %Order{note: "b"} = Ash.get!(Order, "o1", authorize?: false)
    end

    test "an unchanged-TOAST column (absent from record) is preserved on upsert, not clobbered" do
      cfg = config("apply-toast")
      big = String.duplicate("z", 3_000)

      Apply.apply_transaction(
        cfg,
        txn(1, [change(:insert, "orders", %{"id" => "t1", "note" => "n1", "body" => big})])
      )

      # The UPDATE omits "body" (unchanged TOAST) — attrs_for_upsert excludes it, so it is
      # not in upsert_fields and ON MATCH must leave it untouched.
      Apply.apply_transaction(
        cfg,
        txn(2, [change(:update, "orders", %{"id" => "t1", "note" => "n2"}, %{"id" => "t1"})])
      )

      row = Ash.get!(Order, "t1", authorize?: false)
      assert row.note == "n2"
      assert row.body == big
    end

    test "a PK-changing UPDATE destroys the OLD pk then upserts the NEW one (no ghost row)" do
      cfg = config("apply-pkchange")

      Apply.apply_transaction(
        cfg,
        txn(1, [change(:insert, "orders", %{"id" => "p5", "note" => "a"})])
      )

      Apply.apply_transaction(
        cfg,
        txn(2, [change(:update, "orders", %{"id" => "p6", "note" => "a"}, %{"id" => "p5"})])
      )

      assert Ash.get!(Order, "p5", authorize?: false, error?: false) == nil
      assert %Order{note: "a"} = Ash.get!(Order, "p6", authorize?: false)
    end

    # The mirror vertex IDENTITY is (primary key + the tenant discriminator) — the MERGE folds
    # the multitenancy attribute into the upsert identity (`upsert_identity_keys/2`). So a
    # same-PK :update that MOVES the tenant is an IDENTITY change: it must destroy the
    # OLD-(tenant, PK) vertex FIRST (tenant resolved from `old_record` — REPLICA IDENTITY FULL),
    # then upsert into the new tenant. RED against the PK-only `pk_changed?` trigger: with no
    # destroy, the upsert CREATEs a fresh vertex in tenant B (the identity now differs) while the
    # tenant-A vertex is NEVER destroyed → a stale copy the former tenant can still read.
    test "a tenant-MOVE update (same PK, new tenant) destroys the OLD-tenant copy (no stale cross-tenant vertex)" do
      cfg = config("apply-tenant-move")

      Apply.apply_transaction(
        cfg,
        txn(1, [
          change(:insert, "tenant_things", %{
            "id" => "mv1",
            "org_id" => "move_src",
            "note" => "in-a"
          })
        ])
      )

      assert [%TenantThing{note: "in-a"}] =
               Ash.read!(TenantThing, tenant: "move_src", authorize?: false)

      # Same PK "mv1", tenant moves move_src -> move_dst; old_record carries the source tenant.
      assert {:ok, 2} =
               Apply.apply_transaction(
                 cfg,
                 txn(2, [
                   change(
                     :update,
                     "tenant_things",
                     %{"id" => "mv1", "org_id" => "move_dst", "note" => "in-b"},
                     %{"id" => "mv1", "org_id" => "move_src", "note" => "in-a"}
                   )
                 ])
               )

      # The vertex lives ONLY in the destination tenant; the source-tenant copy is GONE.
      assert Ash.read!(TenantThing, tenant: "move_src", authorize?: false) == []

      assert [%TenantThing{note: "in-b"}] =
               Ash.read!(TenantThing, tenant: "move_dst", authorize?: false)
    end

    test "a delete removes the row by PK" do
      cfg = config("apply-delete")

      Apply.apply_transaction(
        cfg,
        txn(1, [change(:insert, "orders", %{"id" => "d1", "note" => "x"})])
      )

      Apply.apply_transaction(cfg, txn(2, [change(:delete, "orders", nil, %{"id" => "d1"})]))

      assert Ash.get!(Order, "d1", authorize?: false, error?: false) == nil
    end

    test "deleting a never-present row is an idempotent no-op that does not over-match" do
      cfg = config("apply-idempotent-delete")

      # A sibling that MUST survive — makes this red-capable against an unscoped DELETE.
      Apply.apply_transaction(
        cfg,
        txn(1, [change(:insert, "orders", %{"id" => "survivor", "note" => "keep"})])
      )

      assert {:ok, 2} =
               Apply.apply_transaction(
                 cfg,
                 txn(2, [change(:delete, "orders", nil, %{"id" => "never-here"})])
               )

      assert %Order{note: "keep"} = Ash.get!(Order, "survivor", authorize?: false)
      assert Ash.get!(Order, "never-here", authorize?: false, error?: false) == nil
    end
  end

  describe "spilled transaction — changes is a lazy single-pass Enumerable (not a list)" do
    @apply_event [:ash_arcadic, :replicant, :transaction, :apply]

    # A spilled/large transaction delivers `changes` as a `Replicant.Spill.Reader` — a lazy,
    # single-pass Enumerable, NOT a list. `run/1` must count the changes DURING its single
    # `Enum` pass. RED against the previous `{:applied, length(changes)}`: `length/1` raises
    # `ArgumentError` on the non-list reader (and the reader is already consumed by the
    # `Enum.each` before it), so `apply_transaction/2` returns `{:error, :sink_failed}` and the
    # whole (large) transaction rolls back — every spilled transaction deterministically crashes.
    test "applies every change + emits the right change_count, never crashing on length/1" do
      cfg = config("apply-spilled")
      ref = :telemetry_test.attach_event_handlers(self(), [@apply_event])

      changes =
        OneShotChanges.wrap([
          change(:insert, "orders", %{"id" => "sp1", "note" => "a"}),
          change(:insert, "orders", %{"id" => "sp2", "note" => "b"})
        ])

      assert {:ok, 42} = Apply.apply_transaction(cfg, txn(42, changes))

      assert_received {@apply_event, ^ref, %{change_count: 2},
                       %{slot: "apply-spilled", commit_lsn: 42}}

      :telemetry.detach(ref)

      assert %Order{note: "a"} = Ash.get!(Order, "sp1", authorize?: false)
      assert %Order{note: "b"} = Ash.get!(Order, "sp2", authorize?: false)
    end
  end

  describe "truncate :mirror (tenant-blind, in-session)" do
    test "clears the WHOLE label across tenants, and the checkpoint advances in the same txn" do
      cfg = config("apply-truncate")

      Ash.create!(TenantThing, %{id: "m1", org_id: "org_1", note: "a"},
        tenant: "org_1",
        authorize?: false
      )

      Ash.create!(TenantThing, %{id: "m2", org_id: "org_2", note: "b"},
        tenant: "org_2",
        authorize?: false
      )

      assert {:ok, 9} =
               Apply.apply_transaction(cfg, txn(9, [change(:truncate, "tenant_things", nil)]))

      assert Ash.read!(TenantThing, tenant: "org_1", authorize?: false) == []
      assert Ash.read!(TenantThing, tenant: "org_2", authorize?: false) == []
      # Advanced atomically with the tenant-blind wipe (same apply_transaction session).
      assert Checkpoint.for_slot("apply-truncate") == 9
    end
  end

  describe "the replay gate end-to-end (F1)" do
    test "F1: a nil (never-applied) checkpoint APPLIES the transaction and advances the watermark" do
      cfg = config("apply-f1-nil")
      assert Checkpoint.for_slot("apply-f1-nil") == nil

      assert {:ok, 7} =
               Apply.apply_transaction(
                 cfg,
                 txn(7, [change(:insert, "orders", %{"id" => "f1", "note" => "hi"})])
               )

      assert %Order{note: "hi"} = Ash.get!(Order, "f1", authorize?: false)
      assert Checkpoint.for_slot("apply-f1-nil") == 7
    end

    test "a replayed transaction (lsn <= stored) is SKIPPED: no change applied, watermark held" do
      cfg = config("apply-replay")
      Checkpoint.upsert_lsn("apply-replay", 10)

      assert {:ok, 10} =
               Apply.apply_transaction(
                 cfg,
                 txn(8, [change(:insert, "orders", %{"id" => "replayed", "note" => "no"})])
               )

      assert Ash.get!(Order, "replayed", authorize?: false, error?: false) == nil
      assert Checkpoint.for_slot("apply-replay") == 10
    end
  end

  describe "value-free error boundary (apply_transaction always returns {:ok|:error}, never leaks)" do
    # A data-layer write failure inside the transaction is delivered as a rollback THROW that
    # `Transaction.run/1` RETURNS as `{:error, <raw data-layer error>}` — bypassing the per-change
    # `rescue`. The raw term is an `%Ash.Error.Invalid{}` CONTAINER that carries the changeset
    # (the source row) — value-BEARING under `inspect`. The boundary must never let it cross.
    test "a data-layer write failure surfaces a VALUE-FREE {:error}, never the value-bearing container" do
      cfg = config("apply-valuefree-boundary")
      # A non-UTF8 binary passes Ash's :string cast but fails the data-layer JSON encode gate.
      poison = "leak-" <> <<0xFF, 0xFE, 0xFD>>

      assert {:error, error} =
               Apply.apply_transaction(
                 cfg,
                 txn(3, [change(:insert, "orders", %{"id" => "vf1", "note" => poison})])
               )

      # The value-bearing Ash.Error container (with its changeset) must NOT cross the boundary.
      refute match?(%Ash.Error.Invalid{}, error)
      refute is_map(error) and Map.has_key?(error, :changeset)

      # What crosses is value-free: our own Error, or a bare structural data-layer error.
      assert match?(%AshArcadic.Replicant.Error{}, error) or
               match?(%AshArcadic.Errors.CreateFailed{}, error)
    end

    # A malformed :update with `record: nil` + a map `old_record` makes `pk_changed?/2` call
    # `Resolver.pk_values(resource, nil)`, whose `is_map` guard raises a raw FunctionClauseError
    # OUTSIDE the per-change rescue. The boundary must convert it to a value-free {:error},
    # never a raw crash on the crux.
    test "a malformed :update (record: nil) fails closed value-free — no raw crash escapes" do
      cfg = config("apply-malformed-update")

      assert {:error, error} =
               Apply.apply_transaction(
                 cfg,
                 txn(4, [change(:update, "orders", nil, %{"id" => "x"})])
               )

      refute match?(%Ash.Error.Invalid{}, error)
      assert match?(%AshArcadic.Replicant.Error{}, error)
    end
  end

  describe "wholesale-empty resolver index fails closed (:empty_index — no invisible loss)" do
    # A mirror sink whose resolver_index is EMPTY (empty/wrong domains) would resolve every
    # change to nil (unmapped → :ok skip) and silently drop the whole transaction WHILE
    # advancing the checkpoint = PERMANENT, INVISIBLE loss. The guard fires BEFORE the
    # transaction opens, so the checkpoint is NOT advanced and the LSN is re-delivered on
    # resume. Distinct from a NON-empty index with one unmapped table (a legitimate
    # partial-publication skip — covered by "an unmapped {schema, table} is ignored (:ok)").
    test "apply_transaction returns {:error, :empty_index} and does NOT advance the checkpoint" do
      empty_cfg = %{
        resolver_index: %{},
        checkpoint: Checkpoint,
        slot: "apply-empty-index",
        authorize?: false
      }

      assert Checkpoint.for_slot("apply-empty-index") == nil

      assert {:error, %AshArcadic.Replicant.Error{reason: :empty_index}} =
               Apply.apply_transaction(
                 empty_cfg,
                 txn(9, [change(:insert, "orders", %{"id" => "leak", "note" => "no"})])
               )

      # loss=0: nothing mirrored AND the checkpoint did NOT advance (a redo re-delivers).
      assert Checkpoint.for_slot("apply-empty-index") == nil
      assert Ash.get!(Order, "leak", authorize?: false, error?: false) == nil
    end
  end
end
