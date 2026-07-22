defmodule AshArcadic.Integration.ReplicantSinkTest do
  @moduledoc false
  # T8 — the DEFINITIVE effect-once verification: prove the slice's central claim END-TO-END
  # through the SINK (`handle_transaction/1` + the Ch3 snapshot callbacks) against a live,
  # throwaway ArcadeDB. Each of the four named proofs (replay no-op, crash atomicity,
  # cross-tenant colliding-PK, snapshot bootstrap) — plus the T6 carry-forward (snapshot-batch
  # atomicity + redo re-clear) — is MUTATION-PROBED for non-vacuity: every test's moduledoc-level
  # comment names the mutation that reddens it, and the task report quotes the live RED for each.
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Replicant.Error
  alias AshArcadic.Test.Replicant.SinkMirror

  # --- The test mirror graph resource: `:attribute`-multitenant, seam-locked write actions +
  # a forbidding policy (only the CDC sink writes, via `authorize?: false`), on the throwaway DB. ---
  defmodule Elixir.AshArcadic.Test.Replicant.SinkMirror do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.SinkMirrorDomain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant],
      authorizers: [Ash.Policy.Authorizer]

    arcade do
      client(AshArcadic.Test.IntegrationClient)
      label(:ReplicantSinkMirror)
    end

    replicant do
      source_table("sink_mirror")
      tenant_attribute(:org_id)
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

  defmodule Elixir.AshArcadic.Test.Replicant.SinkMirrorDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshArcadic.Test.Replicant.SinkMirror
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
      slot_name: "t8-sink-mirror",
      domains: [AshArcadic.Test.Replicant.SinkMirrorDomain]
  end

  @slot "t8-sink-mirror"
  @table "public.sink_mirror"

  # Clean slate per test: the throwaway DB is MODULE-scoped (no per-test reset), so drop every
  # mirror-label vertex AND the slot's checkpoint row, and clear the tx marker + the cached
  # resolver index. Each test then starts from a nil checkpoint on an empty label and drives its
  # own LSN progression.
  setup %{admin: admin} do
    reset = fn ->
      AshArcadic.Transaction.clear()
      Arcadic.command!(admin, "MATCH (n:ReplicantSinkMirror) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:ReplicantCheckpoint) DETACH DELETE n")
      :persistent_term.erase({AshArcadic.Replicant.Sink.Impl, @slot})
    end

    reset.()
    on_exit(reset)
    :ok
  end

  # --- hand-built change / txn / snapshot builders (string-keyed records, like the CDC decoder) ---

  defp change(op, record, old_record \\ nil) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: "sink_mirror",
      record: record,
      old_record: old_record
    }
  end

  defp snap(record) do
    %Replicant.Change{op: :snapshot, schema: "public", table: "sink_mirror", record: record}
  end

  defp txn(lsn, changes), do: %Replicant.Transaction{commit_lsn: lsn, changes: changes}

  defp rec(id, org, note), do: %{"id" => id, "org_id" => org, "note" => note}

  # --- raw ArcadeDB observers (bypass Ash: prove the STORED graph, tenant-blind where needed) ---

  defp label_count(admin) do
    {:ok, [%{"c" => c}]} =
      Arcadic.query(admin, "MATCH (n:ReplicantSinkMirror) RETURN count(n) AS c", %{})

    c
  end

  defp count_by_id(admin, id) do
    {:ok, [%{"c" => c}]} =
      Arcadic.query(
        admin,
        "MATCH (n:ReplicantSinkMirror {id:$id}) RETURN count(n) AS c",
        %{"id" => id}
      )

    c
  end

  # Every stored vertex for `id`, as `%{"org" => ..., "note" => ...}`, ordered by tenant so the
  # cross-tenant assertion is deterministic.
  defp props_by_id(admin, id) do
    {:ok, rows} =
      Arcadic.query(
        admin,
        "MATCH (n:ReplicantSinkMirror {id:$id}) RETURN n.org_id AS org, n.note AS note ORDER BY n.org_id",
        %{"id" => id}
      )

    rows
  end

  defp notes(org) do
    SinkMirror
    |> Ash.read!(tenant: org, authorize?: false)
    |> Enum.map(& &1.note)
    |> Enum.sort()
  end

  describe "effect-once through the sink (handle_transaction/1)" do
    # PROOF 1 — Replay no-op (dup = 0), NON-VACUOUS.
    #
    # A naive "re-deliver the same insert txn, assert count unchanged" is VACUOUS here: the
    # mirror upsert is a native MERGE by (PK + tenant discriminator), so a replayed insert is
    # deduped by the MERGE even with NO replay gate — removing the gate would not redden a count
    # assertion. So we seed a GENUINE already-applied state whose replay is observable: insert r1
    # (lsn 10), then DELETE r1 (lsn 11). Re-delivering the older lsn 10 must be SKIPPED; without
    # the gate it RESURRECTS the deleted r1 (an effect-once violation the MERGE cannot mask).
    #
    # NAMED MUTATION (reddens): weaken `AshArcadic.Replicant.Apply.replay_skip?/2`
    # (`is_integer(stored) and lsn <= stored`) to always-false → the re-delivered lsn 10 re-applies
    # `insert r1` → `count_by_id(r1) == 1` (resurrected) and the watermark reverts 11 → 10.
    test "replay no-op: a re-delivered already-applied commit_lsn is SKIPPED — no resurrection, dup=0",
         %{admin: admin} do
      org = "org1"

      # Seed a genuine already-applied state (checkpoint advances to 11).
      assert {:ok, 10} = Sink.handle_transaction(txn(10, [change(:insert, rec("r1", org, "v1"))]))

      assert {:ok, 11} =
               Sink.handle_transaction(
                 txn(11, [change(:delete, nil, %{"id" => "r1", "org_id" => org})])
               )

      assert count_by_id(admin, "r1") == 0
      assert Checkpoint.for_slot(@slot) == 11

      # Re-deliver the OLDER lsn 10 (a replay: 10 <= 11). The gate SKIPS it, returning the held
      # watermark; r1 stays deleted.
      assert {:ok, 11} = Sink.handle_transaction(txn(10, [change(:insert, rec("r1", org, "v1"))]))

      assert count_by_id(admin, "r1") == 0
      assert Checkpoint.for_slot(@slot) == 11
    end

    # PROOF 2 — Crash atomicity (loss = 0, no partial commit), NON-VACUOUS.
    #
    # A txn whose 2nd change raises mid-apply (a delete missing its PK → :missing_primary_key).
    # r_pre is written into the session BEFORE the raise; r_post never runs. The whole apply must
    # roll back: neither row persists AND the watermark does not advance (all-or-nothing).
    #
    # NAMED MUTATION (reddens): replace `Ash.transaction(resources(config), fn -> run(...) end)` in
    # `Apply.apply_transaction/2` with a bare `{:ok, run(config, lsn, changes)}` (no session) → the
    # pre-failure `insert r_pre` auto-commits on its own base conn and PERSISTS → `count_by_id(r_pre)
    # == 1` reddens (a partial commit).
    test "crash atomicity: a mid-apply failure rolls back ALL data AND the watermark (no partial commit)",
         %{admin: admin} do
      org = "org1"

      crash_txn =
        txn(20, [
          change(:insert, rec("r_pre", org, "pre")),
          # No "id" in old_record → destroy_by_pk fails closed :missing_primary_key, mid-list.
          change(:delete, nil, %{"org_id" => org}),
          change(:insert, rec("r_post", org, "post"))
        ])

      assert {:error, %Error{}} = Sink.handle_transaction(crash_txn)

      assert count_by_id(admin, "r_pre") == 0
      assert count_by_id(admin, "r_post") == 0
      assert Checkpoint.for_slot(@slot) == nil
    end

    # PROOF 3 — Cross-tenant isolation under a COLLIDING primary key (F2 native-MERGE hijack),
    # NON-VACUOUS.
    #
    # The victim vertex shares the attacker's PK ("collide") but lives in a DIFFERENT tenant.
    # Native MERGE has no WHERE, so the tenant discriminator MUST ride the upsert IDENTITY, else
    # the attacker's MERGE MATCHes the victim and its ON MATCH SET mutates it. The attacker is
    # FABRICATED — a hand-built change carrying the ATTACKER's own tenant — never the loaded victim
    # (feedback_cross_tenant_test_fabricates_attacker_not_reuses_loaded). A non-colliding PK would
    # pass regardless; the colliding PK is what makes the gate real.
    #
    # NAMED MUTATION (reddens): drop the discriminator from the MERGE identity in
    # `AshArcadic.DataLayer.upsert_identity_keys/2` (`base_keys ++ [attr]` → `base_keys`) → the
    # attacker's `MERGE {id:"collide"}` MATCHes the victim → the victim's note becomes "attacker"
    # and only ONE vertex carries the PK → `props_by_id("collide")` reddens.
    test "cross-tenant isolation: a foreign-tenant upsert under a COLLIDING PK cannot hijack the victim",
         %{admin: admin} do
      victim_org = "aaa_victim"
      attacker_org = "zzz_attacker"

      # Seed the VICTIM — a genuine mirror row, id "collide", in the victim's tenant.
      Ash.create!(SinkMirror, %{id: "collide", org_id: victim_org, note: "victim"},
        tenant: victim_org,
        authorize?: false
      )

      assert props_by_id(admin, "collide") == [%{"org" => victim_org, "note" => "victim"}]

      # The FABRICATED attacker: the victim's colliding PK, but the attacker's OWN tenant.
      assert {:ok, 5} =
               Sink.handle_transaction(
                 txn(5, [change(:insert, rec("collide", attacker_org, "attacker"))])
               )

      # The victim is byte-unchanged; the attacker's vertex lands in the attacker's tenant only;
      # two DISTINCT vertices now share the PK (one per tenant) — the MERGE did not hijack.
      assert props_by_id(admin, "collide") == [
               %{"org" => victim_org, "note" => "victim"},
               %{"org" => attacker_org, "note" => "attacker"}
             ]

      assert [%SinkMirror{note: "victim"}] =
               Ash.read!(SinkMirror, tenant: victim_org, authorize?: false)

      assert [%SinkMirror{note: "attacker"}] =
               Ash.read!(SinkMirror, tenant: attacker_org, authorize?: false)
    end
  end

  describe "snapshot bootstrap (Ch3) + batch atomicity/redo" do
    # PROOF 4 — Snapshot bootstrap materializes the FULL pre-existing state, NON-VACUOUS.
    #
    # An empty-checkpoint start bootstraps the whole pre-slot state via the snapshot callbacks
    # (not a partial forward-only stream). The checkpoint stays nil until the handoff commit, so a
    # crash mid-snapshot re-runs the whole thing.
    #
    # NAMED MUTATION (reddens): skip the snapshot (comment out the `handle_snapshot/2` call, i.e.
    # go forward-only) → the three pre-slot rows never materialize → `label_count == 3` reddens
    # (stays 0). The pre-snapshot `label_count == 0` assertion brackets the causation.
    test "snapshot bootstrap: an empty-checkpoint start materializes the FULL pre-existing state",
         %{admin: admin} do
      org = "org1"
      assert Sink.checkpoint() == {:ok, nil}
      assert label_count(admin) == 0

      snap_rows = [
        snap(rec("s1", org, "one")),
        snap(rec("s2", org, "two")),
        snap(rec("s3", org, "three"))
      ]

      assert :ok =
               Sink.handle_snapshot(snap_rows, %{
                 table: @table,
                 first_for_table?: true,
                 snapshot_lsn: 99
               })

      # Checkpoint stays nil until the handoff commit.
      assert Sink.checkpoint() == {:ok, nil}

      assert {:ok, 99} = Sink.handle_snapshot_complete(99)

      assert label_count(admin) == 3
      assert notes(org) == ["one", "three", "two"]
      assert Sink.checkpoint() == {:ok, 99}
    end

    # CARRY-FORWARD (T6 review) #1 — snapshot-batch atomicity, NON-VACUOUS.
    #
    # A first batch establishes {a, b}. A REDO batch (first_for_table? → clears first) whose 2nd
    # row is invalid (missing PK) must roll BOTH the clear and the partial upserts back — the table
    # stays {a, b}, never half-cleared / half-loaded (the clear + upserts are ONE atomic session).
    #
    # NAMED MUTATION (reddens): remove the `Ash.transaction([resource], fn -> ... end)` wrapper in
    # `AshArcadic.Replicant.Sink.Impl.run_snapshot_batch/4` (call `apply_snapshot_batch/4` directly)
    # → the clear + `upsert c` auto-commit before the raise → the table becomes {c}, so
    # `notes(org) == ["a", "b"]` and `label_count == 2` redden.
    test "snapshot batch atomicity: a mid-batch failure leaves the table in its PRE-batch state",
         %{admin: admin} do
      org = "org1"

      assert :ok =
               Sink.handle_snapshot([snap(rec("a", org, "a")), snap(rec("b", org, "b"))], %{
                 table: @table,
                 first_for_table?: true,
                 snapshot_lsn: 1
               })

      assert label_count(admin) == 2

      # A redo batch that clears, upserts c, then hits an invalid (PK-less) row.
      bad_batch = [snap(rec("c", org, "c")), snap(%{"org_id" => org, "note" => "no-pk"})]

      assert {:error, %Error{}} =
               Sink.handle_snapshot(bad_batch, %{
                 table: @table,
                 first_for_table?: true,
                 snapshot_lsn: 2
               })

      assert label_count(admin) == 2
      assert notes(org) == ["a", "b"]
    end

    # CARRY-FORWARD (T6 review) #2 — redo re-clear drops a stale row, NON-VACUOUS.
    #
    # Attempt 1 loads {a, b, c}. The source then deletes c; the snapshot RE-RUNS with only {a, b}.
    # first_for_table? clears the prior mirror rows first, so the stale c does NOT survive the redo.
    #
    # NAMED MUTATION (reddens): skip the `first_for_table?` clear in
    # `AshArcadic.Replicant.Sink.Impl.apply_snapshot_batch/4` (remove `if first?, do:
    # Apply.clear_label!(...)`) → the stale c survives → `count_by_id(c) == 0` reddens (stays 1).
    test "snapshot redo re-clear: a redo clears a stale row the source deleted between attempts",
         %{admin: admin} do
      org = "org1"

      assert :ok =
               Sink.handle_snapshot(
                 [snap(rec("a", org, "a")), snap(rec("b", org, "b")), snap(rec("c", org, "c"))],
                 %{table: @table, first_for_table?: true, snapshot_lsn: 1}
               )

      assert notes(org) == ["a", "b", "c"]

      # The source deleted c; the redo delivers only {a, b}.
      assert :ok =
               Sink.handle_snapshot([snap(rec("a", org, "a")), snap(rec("b", org, "b"))], %{
                 table: @table,
                 first_for_table?: true,
                 snapshot_lsn: 1
               })

      assert notes(org) == ["a", "b"]
      assert count_by_id(admin, "c") == 0
    end
  end
end
