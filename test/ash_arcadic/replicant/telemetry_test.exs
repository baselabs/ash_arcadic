defmodule AshArcadic.Replicant.TelemetryUnitTest do
  @moduledoc false
  # No-server unit tests for the value-free allowlist + validate!/1 — the single
  # enforcement point that no row value ever reaches replicant telemetry metadata
  # (AGENTS.md Rule 4 / project_redaction_fail_path_exception_leak).
  use ExUnit.Case, async: true

  alias AshArcadic.Replicant.Telemetry

  describe "the value-free metadata allowlist (mirrors AshArcadic.Telemetry's pattern)" do
    test "slot and commit_lsn are on the allowlist" do
      assert :slot in Telemetry.allowed_meta_keys()
      assert :commit_lsn in Telemetry.allowed_meta_keys()
    end

    test "validate!/1 passes an allowlisted map through unchanged" do
      meta = %{slot: "s1", commit_lsn: 5}
      assert Telemetry.validate!(meta) == meta
    end

    test "validate!/1 raises on an off-allowlist key (no row-level or tenant-derived value)" do
      assert_raise ArgumentError, ~r/allowlist/, fn ->
        Telemetry.validate!(%{slot: "s1", record: %{"secret" => "leak"}})
      end
    end

    test "does not reuse the data-layer AshArcadic.Telemetry allowlist (no slot/commit_lsn there)" do
      refute :slot in AshArcadic.Telemetry.allowed_meta_keys()
      refute :commit_lsn in AshArcadic.Telemetry.allowed_meta_keys()
    end
  end
end

defmodule AshArcadic.Replicant.TelemetryIntegrationTest do
  @moduledoc false
  # Live-DB proof that `[:ash_arcadic, :replicant, :transaction, :apply]` and
  # `[:ash_arcadic, :replicant, :transaction, :skip]` fire on the correct outcome
  # (and NEITHER on an `{:error, _}` outcome), with value-free metadata — the
  # positive control that a distinctive row value never reaches telemetry.
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Replicant.Apply

  defmodule Item do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant],
      authorizers: [Ash.Policy.Authorizer]

    arcade do
      client(AshArcadic.Test.IntegrationClient)
      label(:TelemetryItem)
    end

    replicant do
      source_table("items")
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
      client: AshArcadic.Test.IntegrationClient
  end

  @apply_event [:ash_arcadic, :replicant, :transaction, :apply]
  @skip_event [:ash_arcadic, :replicant, :transaction, :skip]

  defp config(slot) do
    %{
      resolver_index: %{{"public", "items"} => Item},
      checkpoint: Checkpoint,
      slot: slot,
      authorize?: false
    }
  end

  defp change(op, record, old_record \\ nil) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: "items",
      record: record,
      old_record: old_record
    }
  end

  defp txn(lsn, changes), do: %Replicant.Transaction{commit_lsn: lsn, changes: changes}

  defp attach(events), do: :telemetry_test.attach_event_handlers(self(), events)

  describe "the :apply event" do
    test "fires on a real apply with change_count/duration measurements and value-free metadata" do
      ref = attach([@apply_event, @skip_event])
      cfg = config("telemetry-apply")

      assert {:ok, 1} =
               Apply.apply_transaction(
                 cfg,
                 txn(1, [change(:insert, %{"id" => "i1", "note" => "a"})])
               )

      assert_received {@apply_event, ^ref, measurements, meta}
      refute_received {@skip_event, ^ref, _measurements, _meta}

      # Metadata is slot + commit_lsn ONLY (Contract) — never a record, column value, or tenant.
      assert meta == %{slot: "telemetry-apply", commit_lsn: 1}
      assert measurements.change_count == 1
      assert is_integer(measurements.duration)
    end

    test "change_count equals the number of changes applied" do
      ref = attach([@apply_event])
      cfg = config("telemetry-apply-multi")

      assert {:ok, 1} =
               Apply.apply_transaction(
                 cfg,
                 txn(1, [
                   change(:insert, %{"id" => "m1", "note" => "a"}),
                   change(:insert, %{"id" => "m2", "note" => "b"})
                 ])
               )

      assert_received {@apply_event, ^ref, %{change_count: 2}, _meta}
    end
  end

  describe "the :skip event" do
    test "fires on a replay-gate hit; no :apply event fires" do
      cfg = config("telemetry-skip")
      Checkpoint.upsert_lsn("telemetry-skip", 10)

      ref = attach([@apply_event, @skip_event])

      assert {:ok, 10} =
               Apply.apply_transaction(
                 cfg,
                 txn(8, [change(:insert, %{"id" => "s1", "note" => "x"})])
               )

      assert_received {@skip_event, ^ref, _measurements, meta}
      refute_received {@apply_event, ^ref, _measurements, _meta}

      assert meta == %{slot: "telemetry-skip", commit_lsn: 8}
      # The skipped change never actually applied.
      assert Ash.get!(Item, "s1", authorize?: false, error?: false) == nil
    end
  end

  describe "an {:error, _} outcome" do
    test "fires NEITHER event (no telemetry on a rolled-back apply)" do
      ref = attach([@apply_event, @skip_event])
      cfg = config("telemetry-error")
      # A non-UTF8 binary passes Ash's :string cast but fails the data-layer JSON encode
      # gate (same construction as the value-free-boundary test in apply_test.exs).
      poison = "leak-" <> <<0xFF, 0xFE, 0xFD>>

      assert {:error, _reason} =
               Apply.apply_transaction(
                 cfg,
                 txn(3, [change(:insert, %{"id" => "e1", "note" => poison})])
               )

      refute_received {@apply_event, ^ref, _measurements, _meta}
      refute_received {@skip_event, ^ref, _measurements, _meta}
    end
  end

  describe "value-absence positive control (Contract: metadata is slot + commit_lsn ONLY)" do
    test "a distinctive row value never appears in the emitted metadata or measurements" do
      ref = attach([@apply_event, @skip_event])
      cfg = config("telemetry-canary")
      canary = "CANARY-#{System.unique_integer([:positive])}-do-not-leak"

      assert {:ok, 1} =
               Apply.apply_transaction(
                 cfg,
                 txn(1, [change(:insert, %{"id" => "c1", "note" => canary})])
               )

      assert_received {@apply_event, ^ref, measurements, meta}
      refute inspect({measurements, meta}) =~ canary
      assert meta == %{slot: "telemetry-canary", commit_lsn: 1}
    end
  end
end
