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

  # Fail-closed arm parity with the single-row create (atomic_create_upsert_test.exs): the BULK upsert
  # path had no coverage for a rejected atomic fold. `:bad_atomic_rhs` carries atomic_set(:count,
  # expr(dec + ^arg(:secret))) — the :decimal field-ref RHS is rejected by upsert_atomic_set ->
  # Write.atomic_fragments -> {:error, %UnsupportedFilter{}} BEFORE bulk_conn. run_bulk_upsert's else
  # must normalize it to a value-free %CreateFailed{}, never leak the raw filter-flavored error or the
  # caller operand. Driven at the data-layer callback directly, exactly as the single-row test does.
  test "a bulk upsert whose atomic fold is rejected returns a value-free CreateFailed (not UnsupportedFilter)" do
    cs = Ash.Changeset.for_create(AtomicCounter, :bad_atomic_rhs, %{id: "b1", secret: 31_337})

    assert {:error, err} =
             AshArcadic.DataLayer.bulk_create(AtomicCounter, [cs], %{
               upsert?: true,
               upsert_keys: [:id],
               return_records?: true
             })

    refute match?(%AshArcadic.Errors.UnsupportedFilter{}, err)
    assert %AshArcadic.Errors.CreateFailed{reason: "unsupported atomic change"} = err
    refute inspect(err) =~ "31337"
    refute inspect(err) =~ "31_337"
  end

  # The atomic-param encode-gate on the BULK upsert path (run_bulk_upsert line 1630 gates the atomic
  # $paramN literals). `:upsert_poison` folds atomic_update(:label_txt, expr(label_txt <> ^arg(:bad)))
  # ON MATCH, binding the poisoned non-UTF8 arg RAW into an atomic param. The gate must turn it into a
  # value-free {:error, _} before bulk_conn, never a Jason.EncodeError with the bytes (Rule 4) — mirror
  # of the single-row :upsert_poison regression.
  test "a poisoned non-UTF8 binary in a bulk upsert ON MATCH atomic RHS fails closed value-free" do
    bad = <<0xFF, 0xFE>>
    cs = Ash.Changeset.for_create(AtomicCounter, :upsert_poison, %{id: "up1", bad: bad})

    assert {:error, err} =
             AshArcadic.DataLayer.bulk_create(AtomicCounter, [cs], %{
               upsert?: true,
               upsert_keys: [:id],
               return_records?: true
             })

    assert %AshArcadic.Errors.CreateFailed{} = err
    refute inspect(err) =~ "255"
    refute inspect(err) =~ "0xFF"
  end
end
