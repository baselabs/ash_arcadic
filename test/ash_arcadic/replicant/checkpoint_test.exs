defmodule AshArcadic.Replicant.CheckpointCompareTest do
  @moduledoc false
  # Cheap, non-integration unit demonstration (no ArcadeDB, no macro) of WHY
  # `last_commit_lsn` must be `:integer`, never `:string`: T5's replay gate is
  # `is_integer(stored) and lsn <= stored`. Under a genuine integer compare, a
  # higher lsn is NOT <= a lower stored value, so it is admitted (applied). Under a
  # `:string` store, `<=` is lexicographic — for multi-digit values that INVERTS the
  # gate: `"10" <= "9"` is true (string compare), so a string-typed store would
  # wrongly SKIP applying lsn 10 over a stored watermark of "9". This is the Ch5/D8
  # tripwire; the live round-trip proof is in `CheckpointTest` below.
  use ExUnit.Case, async: true

  test "an integer compare admits a higher multi-digit lsn over a lower stored watermark" do
    refute 10 <= 9
  end

  test "a string compare of the SAME values is lexicographic and inverts the gate" do
    assert "10" <= "9"
  end
end

defmodule AshArcadic.Replicant.CheckpointTest do
  use AshArcadic.Test.IntegrationCase

  defmodule Checkpoint do
    @moduledoc false
    use AshArcadic.ReplicantCheckpoint,
      domain: AshArcadic.Test.Domain,
      client: AshArcadic.Test.IntegrationClient
  end

  describe "for_slot/1 and upsert_lsn/2 (live ArcadeDB integer round-trip)" do
    test "for_slot on an unknown slot returns nil (the never-applied case)" do
      assert Checkpoint.for_slot("checkpoint-never-seen") == nil
    end

    test "upsert_lsn then for_slot reads back the SAME integer" do
      Checkpoint.upsert_lsn("checkpoint-roundtrip", 42)

      stored = Checkpoint.for_slot("checkpoint-roundtrip")
      assert stored === 42
      assert is_integer(stored)
    end

    test "upsert_lsn on an existing slot updates (not duplicates) the row" do
      Checkpoint.upsert_lsn("checkpoint-replace", 1)
      Checkpoint.upsert_lsn("checkpoint-replace", 2)

      assert Checkpoint.for_slot("checkpoint-replace") === 2
    end

    test "the <= replay gate admits a higher lsn and skips a lower/equal one, over the round-tripped value" do
      Checkpoint.upsert_lsn("checkpoint-gate", 10)
      stored = Checkpoint.for_slot("checkpoint-gate")
      assert stored === 10

      # a higher lsn is NOT <= stored => admitted (applied)
      refute is_integer(stored) and 15 <= stored
      # a lower lsn IS <= stored => skipped
      assert is_integer(stored) and 9 <= stored
      # an equal lsn IS <= stored => skipped
      assert is_integer(stored) and 10 <= stored
    end
  end

  describe "seam-lock" do
    test "a write without authorize?: false is forbidden" do
      result =
        Checkpoint
        |> Ash.Changeset.for_create(:upsert, %{
          slot_name: "checkpoint-seam-locked",
          last_commit_lsn: 1
        })
        |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} = result
      assert Checkpoint.for_slot("checkpoint-seam-locked") == nil
    end

    test "upsert_lsn's authorize?: false bypasses the seam-lock and succeeds" do
      Checkpoint.upsert_lsn("checkpoint-seam-ok", 7)

      assert Checkpoint.for_slot("checkpoint-seam-ok") === 7
    end
  end
end
