defmodule AshArcadic.Integration.BulkUpsertTest do
  @moduledoc false
  use AshArcadic.Test.IntegrationCase

  # UpsertThing (test/support/resources/upsert_thing.ex): non-multitenant, PK :code, a `:upsert`
  # action (`upsert? true`, no explicit identity → upserts on the PK :code). Ash requires
  # `upsert_fields` for a BULK upsert (deps/ash actions/create/bulk.ex:126).
  alias AshArcadic.Test.UpsertThing

  # AtomicCounter (test/support/resources/atomic_counter.ex): PK :id, `:upsert_create_bump`
  # (atomic_set → changeset.create_atomics → ON CREATE) and `:upsert_bump` (atomic_update →
  # changeset.atomics → ON MATCH). Exercises the V8 atomic-fold surface on the bulk path.
  alias AshArcadic.Test.AtomicCounter

  setup %{admin: admin} do
    on_exit(fn ->
      Arcadic.command!(admin, "MATCH (n:UpsertThing) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:AtomicCounter) DETACH DELETE n")
    end)

    :ok
  end

  test "multi-row bulk upsert: existing rows update, new rows create, one statement" do
    UpsertThing |> Ash.Changeset.for_create(:create, %{code: "a", name: "old-a"}) |> Ash.create!()
    UpsertThing |> Ash.Changeset.for_create(:create, %{code: "b", name: "old-b"}) |> Ash.create!()

    inputs = [
      %{code: "a", name: "new-a"},
      %{code: "b", name: "new-b"},
      %{code: "z", name: "new-z"}
    ]

    %Ash.BulkResult{status: :success} =
      Ash.bulk_create(inputs, UpsertThing, :upsert,
        upsert?: true,
        upsert_fields: [:name],
        return_records?: true
      )

    rows = Ash.read!(UpsertThing)

    # Row COUNT, not just the by-code map: a CREATE-instead-of-MERGE regression (the
    # duplicate-create fail-open this feature prevents) would leave the seeded "a"/"b"
    # plus fresh duplicates (5 rows), but `Map.new` below collapses by code and would
    # hide it. Exactly 3 distinct codes (a/b/z), no duplicates.
    assert length(rows) == 3
    assert Map.new(rows, &{&1.code, &1.name}) == %{"a" => "new-a", "b" => "new-b", "z" => "new-z"}
  end

  test "bulk upsert is idempotent (re-run yields the same rows, no duplicates)" do
    inputs = [%{code: "x", name: "one"}]
    opts = [upsert?: true, upsert_fields: [:name]]

    Ash.bulk_create(inputs, UpsertThing, :upsert, opts)
    Ash.bulk_create(inputs, UpsertThing, :upsert, opts)

    xs = UpsertThing |> Ash.read!() |> Enum.filter(&(&1.code == "x"))
    assert length(xs) == 1
  end

  # V8 fold surface — ON CREATE. `:upsert_create_bump` puts atomic_set(:count, 100+1) in
  # changeset.create_atomics; on the INSERT branch the bulk MERGE must fold it into
  # `ON CREATE SET n += r.all, n.count = 100 + 1`. upsert_fields :label_txt (NOT :count),
  # so the ON MATCH `r.set` never carries count — but for a fresh id ON CREATE runs anyway.
  # Dropping the create_set fold leaves count nil (RED).
  test "bulk upsert folds a create-phase atomic on the INSERT branch (ON CREATE)" do
    %Ash.BulkResult{status: :success} =
      Ash.bulk_create([%{id: "c1"}], AtomicCounter, :upsert_create_bump,
        upsert?: true,
        upsert_fields: [:label_txt],
        return_records?: true
      )

    row = AtomicCounter |> Ash.read!() |> Enum.find(&(&1.id == "c1"))
    assert row.count == 101
  end

  # V8 fold surface — ON MATCH. `:upsert_bump` puts atomic_update(:count, count + 5) in
  # changeset.atomics; on the MATCH branch the bulk MERGE must fold it into
  # `ON MATCH SET n += r.set, n.count = n.count + 5`. upsert_fields :label_txt (NOT :count)
  # so `r.set` cannot clobber the atomically-updated field. Seed count=10 → expect 15.
  # Dropping the match_set fold leaves count at 10 (RED).
  test "bulk upsert folds a match-phase atomic on the MATCH branch (ON MATCH)" do
    AtomicCounter |> Ash.Changeset.for_create(:create, %{id: "m1", count: 10}) |> Ash.create!()

    %Ash.BulkResult{status: :success} =
      Ash.bulk_create([%{id: "m1"}], AtomicCounter, :upsert_bump,
        upsert?: true,
        upsert_fields: [:label_txt],
        return_records?: true
      )

    row = AtomicCounter |> Ash.read!() |> Enum.find(&(&1.id == "m1"))
    assert row.count == 15
  end
end
