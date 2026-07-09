defmodule AshArcadic.Test.CalculationsTest do
  use AshArcadic.Test.IntegrationCase
  require Ash.Query
  alias AshArcadic.Test.CalcPerson, as: P

  # CalcPerson is non-tenant → ONE base DB shared across every test in this file. DETACH DELETE all
  # CalcPerson after each test (mirrors aggregate_test.exs) so a prior test's p1/p2 don't accumulate
  # into another test's full-table sort order/count. admin comes from IntegrationCase.
  setup %{admin: admin} do
    {:ok, _} =
      Ash.create(P, %{
        id: "p1",
        first: "Ada",
        last: "Lovelace",
        a: 10,
        b: 3,
        secret: <<0, 255, 1>>
      })

    {:ok, _} =
      Ash.create(P, %{id: "p2", first: "Alan", last: "Turing", a: 2, b: 2, secret: <<2, 254>>})

    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CalcPerson) DETACH DELETE n") end)
    :ok
  end

  test "loads an expression calc (Elixir eval; flat RETURN n keeps every attribute)" do
    {:ok, rows} = Ash.read(Ash.Query.load(P, [:full_name, :total]))
    by_id = Map.new(rows, &{&1.id, &1})
    # C1 non-vacuity guard: PK + attributes present (not the all-nil nested-decode bug).
    assert by_id["p1"].id == "p1"
    assert by_id["p1"].first == "Ada"
    assert by_id["p1"].full_name == "Ada Lovelace"
    assert by_id["p1"].total == 13
  end

  test "loads a module calc (Elixir runtime, unchanged)" do
    {:ok, [row | _]} = Ash.read(Ash.Query.load(P, [:greeting]) |> Ash.Query.filter(id == "p1"))
    assert row.greeting == "Hi Ada"
  end

  test "TRIPWIRE: loading a calc over a SENSITIVE field fails closed value-free (never evals ciphertext)" do
    assert {:error, error} = Ash.read(Ash.Query.load(P, [:secret_calc]))
    msg = Exception.message(error)
    refute msg =~ "\\xFF"
    refute msg =~ "secret_ciphertext"
  end

  test "sorts by an expression calc (ORDER BY the translated expression)" do
    # total: p1=13, p2=4 → asc order [p2, p1]; desc → [p1, p2].
    {:ok, asc} = Ash.read(Ash.Query.sort(P, total: :asc))
    assert Enum.map(asc, & &1.id) == ["p2", "p1"]
    {:ok, desc} = Ash.read(Ash.Query.sort(P, total: :desc))
    assert Enum.map(desc, & &1.id) == ["p1", "p2"]
  end

  test "sorts by a string expression calc" do
    {:ok, rows} = Ash.read(Ash.Query.sort(P, full_name: :asc))
    # "Ada Lovelace" < "Alan Turing"
    assert Enum.map(rows, & &1.id) == ["p1", "p2"]
  end

  test "TRIPWIRE: sorting by a calc over a sensitive field fails closed value-free" do
    assert {:error, %Ash.Error.Invalid{}} = Ash.read(Ash.Query.sort(P, secret_calc: :asc))
  end
end
