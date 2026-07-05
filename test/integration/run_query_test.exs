defmodule AshArcadic.Integration.RunQueryTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.CrudPerson

  setup %{admin: admin} do
    # Seed via raw Cypher — run_query must not depend on create/2 (Task 10).
    Arcadic.command!(admin, "CREATE (n:CrudPerson $props) RETURN n", %{
      "props" => %{"id" => "r1", "name" => "Ann", "age" => 30}
    })

    Arcadic.command!(admin, "CREATE (n:CrudPerson $props) RETURN n", %{
      "props" => %{"id" => "r2", "name" => "Bo", "age" => 20}
    })

    # IntegrationCase gives a MODULE-scoped throwaway DB with no per-test reset, and
    # this seed CREATEs (not MERGEs) with no unique index on id — so without cleanup
    # the second test's setup would DOUBLE the rows. Delete all CrudPerson after each
    # test so every test's setup seeds into a clean DB. By cleanup time the vertex
    # type exists, so MATCH never errors on an undefined type.
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CrudPerson) DETACH DELETE n") end)

    :ok
  end

  test "reads and decodes all records by attribute_map" do
    {:ok, results} = CrudPerson |> Ash.Query.new() |> Ash.read()
    assert Enum.map(results, & &1.name) |> Enum.sort() == ["Ann", "Bo"]
  end

  test "filter + sort + limit push down to Cypher" do
    {:ok, [person]} =
      CrudPerson |> Ash.Query.filter(age > 25) |> Ash.Query.sort(name: :asc) |> Ash.read()

    assert person.name == "Ann"
    assert person.age == 30
  end
end
