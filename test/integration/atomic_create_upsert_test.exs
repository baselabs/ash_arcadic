defmodule AshArcadic.Integration.AtomicCreateUpsertTest do
  @moduledoc false
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Test.AtomicCounter

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:AtomicCounter) DETACH DELETE n") end)
    :ok
  end

  test "atomic_set on create is applied (create_atomics folded into create/2 — V8)" do
    rec =
      AtomicCounter |> Ash.Changeset.for_create(:create_with_bump, %{id: "c1"}) |> Ash.create!()

    assert rec.count == 101
    assert Ash.get!(AtomicCounter, "c1").count == 101
  end

  test "atomic change on upsert ON MATCH is applied (atomics folded into upsert/3 — V8)" do
    AtomicCounter |> Ash.Changeset.for_create(:create, %{id: "u1", count: 10}) |> Ash.create!()

    # :upsert_bump carries upsert? true (PK identity) + atomic_update(:count, expr(count + 5)).
    AtomicCounter
    |> Ash.Changeset.for_create(:upsert_bump, %{id: "u1"})
    |> Ash.create!()

    assert Ash.get!(AtomicCounter, "u1").count == 15
  end

  test "atomic_set on bulk create is applied (create_atomics folded into run_bulk_create — V8)" do
    # bulk_create routes to run_bulk_create; advertising {:atomic, :create} makes Ash push
    # create_atomics to it too. Both rows share :create_with_bump's create_atomics (Ash groups by
    # them). If run_bulk_create dropped the fold, count would be nil (never set) — this asserts it.
    result =
      Ash.bulk_create([%{id: "bc1"}, %{id: "bc2"}], AtomicCounter, :create_with_bump,
        return_records?: true
      )

    assert result.status == :success
    assert result.records |> Enum.map(& &1.count) |> Enum.sort() == [101, 101]
    assert Ash.get!(AtomicCounter, "bc1").count == 101
    assert Ash.get!(AtomicCounter, "bc2").count == 101
  end

  test "atomic_set on upsert-INSERT is applied ON CREATE (create_atomics folded into upsert/3 — V8)" do
    # No pre-existing row → the MERGE takes the ON CREATE branch. atomic_set populates
    # create_atomics (create phase), which must fold into ON CREATE SET (not ON MATCH). If dropped,
    # count is nil (never computed on insert).
    AtomicCounter
    |> Ash.Changeset.for_create(:upsert_create_bump, %{id: "uc1"})
    |> Ash.create!()

    assert Ash.get!(AtomicCounter, "uc1").count == 101
  end

  test "a poisoned non-UTF8 binary in an upsert ON MATCH atomic RHS fails closed value-free" do
    bad = <<0xFF, 0xFE>>
    # Pre-create the row so the MERGE takes the ON MATCH branch (where the atomic RHS binds the
    # poisoned $paramN). The upsert-path encode-gate must turn it into a value-free {:error, _},
    # never a Jason.EncodeError with the bytes (Rule 4) — mirrors the create-path poison regression.
    AtomicCounter
    |> Ash.Changeset.for_create(:create, %{id: "up1", label_txt: "x"})
    |> Ash.create!()

    result =
      AtomicCounter
      |> Ash.Changeset.for_create(:upsert_poison, %{id: "up1", bad: bad})
      |> Ash.create()

    assert {:error, err} = result
    refute inspect(err) =~ "255"
    refute inspect(err) =~ "0xFF"
  end

  test "a poisoned non-UTF8 binary in an atomic create RHS fails closed value-free" do
    bad = <<0xFF, 0xFE>>

    # The concat RHS stays a genuine EXPRESSION, so the poison rides create_atomics into the
    # atomic-fragment $paramN literals (bound RAW by Expression) — the widened encode-gate must
    # turn it into a value-free {:error, _}, never a Jason.EncodeError with the bytes.
    result =
      AtomicCounter
      |> Ash.Changeset.for_create(:poison_name, %{id: "p", bad: bad})
      |> Ash.create()

    assert {:error, err} = result
    refute inspect(err) =~ "255"
    refute inspect(err) =~ "0xFF"
  end

  test "a create whose atomic fold is rejected returns a value-free CreateFailed (not UnsupportedFilter)" do
    # :bad_atomic_rhs carries atomic_set(:count, expr(dec + ^arg(:secret))) — the :decimal
    # field-ref RHS is rejected by Expression.ref_ok? inside the fold, so create_atomic_set
    # returns {:error, %UnsupportedFilter{}}. do_create's else must normalize it to a
    # value-free %CreateFailed{} (sibling parity with do_update_query_statement's
    # update_query normalization), never leak the raw filter-flavored error from the
    # create/2 callback.
    cs = Ash.Changeset.for_create(AtomicCounter, :bad_atomic_rhs, %{id: "bad1", secret: 31_337})

    assert {:error, err} = AshArcadic.DataLayer.create(AtomicCounter, cs)
    refute match?(%AshArcadic.Errors.UnsupportedFilter{}, err)
    assert %AshArcadic.Errors.CreateFailed{} = err
    # value-free: the caller-supplied atomic operand never rides the error
    refute inspect(err) =~ "31337"
    refute inspect(err) =~ "31_337"
  end
end
