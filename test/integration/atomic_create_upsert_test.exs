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
end
