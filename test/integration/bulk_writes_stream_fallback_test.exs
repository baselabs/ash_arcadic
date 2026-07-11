defmodule AshArcadic.Integration.BulkWritesStreamFallbackTest do
  @moduledoc """
  Evidence for spec §1: query-scoped bulk update/destroy ALREADY work via Ash's
  `:stream` fallback (can?(:update_query) is false at this point → Ash reads matches
  then calls the single-row update/2/destroy/2 per record). This is the "already
  works" claim as evidence, not assertion; it also guards the fallback against
  regression when Plan 1 flips the push-down capabilities.
  """
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.CrudPerson

  setup %{admin: admin} do
    # IntegrationCase provides a throwaway DB + the tenant-blind conn; CrudPerson is
    # a non-multitenant :string-PK resource (test/support/resources/crud_person.ex).
    # DETACH DELETE after each test — ArcadeDB has no PK uniqueness, so a re-seed would accumulate.
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CrudPerson) DETACH DELETE n") end)
    :ok = seed_people()
    :ok
  end

  defp seed_people do
    for {id, name, age} <- [{"p1", "Ann", 30}, {"p2", "Bo", 40}, {"p3", "Cy", 30}] do
      CrudPerson
      |> Ash.Changeset.for_create(:create, %{id: id, name: name, age: age})
      |> Ash.create!()
    end

    :ok
  end

  test "bulk update over a query works via :stream fallback" do
    # can?(:update_query) is false here → Ash streams matches and calls update/2 per row.
    result =
      CrudPerson
      |> Ash.Query.filter(age == 30)
      |> Ash.bulk_update!(:update, %{name: "Renamed"}, return_records?: true, strategy: :stream)

    names = result.records |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["Renamed", "Renamed"]

    # p2 (age 40) untouched.
    assert Ash.get!(CrudPerson, "p2").name == "Bo"
  end

  test "bulk destroy over a query works via :stream fallback" do
    CrudPerson
    |> Ash.Query.filter(age == 30)
    |> Ash.bulk_destroy!(:destroy, %{}, strategy: :stream)

    remaining = CrudPerson |> Ash.read!() |> Enum.map(& &1.id) |> Enum.sort()
    assert remaining == ["p2"]
  end
end
