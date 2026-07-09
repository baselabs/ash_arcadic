defmodule AshArcadic.Test.CalculationsTest do
  use AshArcadic.Test.IntegrationCase
  require Ash.Query
  alias AshArcadic.Test.CalcPerson, as: P

  setup do
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
end
