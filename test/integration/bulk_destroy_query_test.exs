defmodule AshArcadic.Integration.BulkDestroyQueryTest do
  @moduledoc false
  use AshArcadic.Test.IntegrationCase

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

  test "one-statement bulk destroy scoped by the query" do
    CrudPerson
    |> Ash.Query.filter(age == 30)
    |> Ash.bulk_destroy!(:destroy, %{}, strategy: :atomic)

    remaining = CrudPerson |> Ash.read!() |> Enum.map(& &1.id) |> Enum.sort()
    assert remaining == ["p2"]
  end

  test "return_records? true captures the deleted rows' properties (pre-delete, P3)" do
    result =
      CrudPerson
      |> Ash.Query.filter(age == 30)
      |> Ash.bulk_destroy!(:destroy, %{}, strategy: :atomic, return_records?: true)

    names = result.records |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["Ann", "Cy"]
    assert Enum.all?(result.records, &(&1.id in ["p1", "p3"]))
  end

  test "empty-match bulk destroy is a no-op (NOT StaleRecord) — spec D2" do
    result =
      CrudPerson
      |> Ash.Query.filter(age == 999)
      |> Ash.bulk_destroy!(:destroy, %{}, strategy: :atomic, return_records?: true)

    assert result.status == :success
    assert result.records == []
    assert length(Ash.read!(CrudPerson)) == 3
  end

  test "a limit/offset bulk destroy fails closed (no silent unscoped delete)" do
    result =
      CrudPerson
      |> Ash.Query.filter(age == 30)
      |> Ash.Query.limit(1)
      |> Ash.bulk_destroy(:destroy, %{}, strategy: [:atomic], return_errors?: true)

    assert result.status == :error
    # Non-vacuity: nothing deleted (the reject ran before any statement).
    assert length(Ash.read!(CrudPerson)) == 3
  end
end
