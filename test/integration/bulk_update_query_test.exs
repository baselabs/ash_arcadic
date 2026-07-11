defmodule AshArcadic.Integration.BulkUpdateQueryTest do
  @moduledoc false
  use AshArcadic.Test.IntegrationCase

  require Ash.Expr
  require Ash.Query
  alias AshArcadic.Test.CrudPerson

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CrudPerson) DETACH DELETE n") end)

    for {id, name, age} <- [{"p1", "Ann", 30}, {"p2", "Bo", 40}, {"p3", "Cy", 30}] do
      CrudPerson
      |> Ash.Changeset.for_create(:create, %{id: id, name: name, age: age})
      |> Ash.create!()
    end

    :ok
  end

  test "atomic increment pushes down to one SET statement, return_records? true" do
    result =
      CrudPerson
      |> Ash.Query.filter(age == 30)
      |> Ash.bulk_update!(:update, %{age: Ash.Expr.expr(age + 100)},
        strategy: :atomic,
        return_records?: true
      )

    ages = result.records |> Enum.map(& &1.age) |> Enum.sort()
    assert ages == [130, 130]
    assert Ash.get!(CrudPerson, "p2").age == 40
  end

  test "static bulk update, return_records? false returns :ok-shaped result and mutates" do
    CrudPerson
    |> Ash.Query.filter(age == 30)
    |> Ash.bulk_update!(:update, %{name: "Renamed"}, strategy: :atomic, return_records?: false)

    names = CrudPerson |> Ash.read!() |> Enum.filter(&(&1.age == 30)) |> Enum.map(& &1.name)
    assert names == ["Renamed", "Renamed"]
  end

  test "empty-match bulk update is a no-op (NOT StaleRecord) — spec D2" do
    result =
      CrudPerson
      |> Ash.Query.filter(age == 999)
      |> Ash.bulk_update!(:update, %{name: "X"}, strategy: :atomic, return_records?: true)

    assert result.status == :success
    assert result.records == []
  end

  test "a poisoned non-UTF8 binary in an atomic RHS fails closed value-free (encode-gate covers atomic params)" do
    bad = <<0xFF, 0xFE>>

    # Ash.bulk_update (non-bang) returns a BulkResult with :error status rather than raising —
    # the encode-gate must turn the poisoned atomic into a value-free UpdateFailed, never a
    # Jason.EncodeError with the bytes in the message.
    result =
      CrudPerson
      |> Ash.Query.filter(age == 30)
      |> Ash.bulk_update(:update, %{name: Ash.Expr.expr(name <> ^bad)},
        strategy: :atomic,
        return_errors?: true
      )

    assert result.status == :error
    # Value-free: the raw bytes never appear in any error surfaced.
    refute inspect(result.errors) =~ "255"
    refute inspect(result.errors) =~ "0xFF"
  end
end
