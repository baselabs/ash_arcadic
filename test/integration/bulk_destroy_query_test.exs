defmodule AshArcadic.Integration.BulkDestroyQueryTest do
  @moduledoc false
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  require Ash.Expr
  alias Ash.Query.Combination
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

  test "an offset bulk destroy fails closed (offset>0 arm of the scopeable guard)" do
    result =
      CrudPerson
      |> Ash.Query.filter(age == 30)
      |> Ash.Query.offset(1)
      |> Ash.bulk_destroy(:destroy, %{}, strategy: [:atomic], return_errors?: true)

    assert result.status == :error
    # Non-vacuity: nothing deleted (dropping the offset would delete the age==30 rows).
    assert length(Ash.read!(CrudPerson)) == 3
  end

  test "a combination bulk destroy fails closed (combination_of arm of the scopeable guard)" do
    # A combination query reaches destroy_query with combination_of != [] — the guard must
    # reject it fail-closed (a combined-set bulk destroy has no single MATCH … DELETE form).
    combined =
      CrudPerson
      |> Ash.Query.combination_of([
        Combination.base(filter: Ash.Expr.expr(age == 30)),
        Combination.union(filter: Ash.Expr.expr(age == 40))
      ])

    result = Ash.bulk_destroy(combined, :destroy, %{}, strategy: [:atomic], return_errors?: true)

    assert result.status == :error
    # Non-vacuity: nothing deleted (dropping the guard arm would run an unscoped DELETE).
    assert length(Ash.read!(CrudPerson)) == 3
  end
end
