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
end
