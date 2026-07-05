defmodule AshArcadic.Integration.CreateTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.CrudPerson

  test "create persists and returns the record" do
    {:ok, p} =
      CrudPerson
      |> Ash.Changeset.for_create(:create, %{id: "c1", name: "Ann", age: 30})
      |> Ash.create()

    assert p.id == "c1"
    assert p.name == "Ann"
  end

  test ":date and :decimal round-trip through the live engine (not a self-signed unit round-trip)" do
    {:ok, _} =
      CrudPerson
      |> Ash.Changeset.for_create(:create, %{
        id: "c2",
        name: "Bo",
        born: ~D[2000-01-02],
        amount: Decimal.new("12.34")
      })
      |> Ash.create()

    {:ok, [reloaded]} = CrudPerson |> Ash.Query.filter(id == "c2") |> Ash.read()
    assert reloaded.born == ~D[2000-01-02]
    assert reloaded.amount == Decimal.new("12.34")
  end
end
