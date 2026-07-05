defmodule AshArcadic.Integration.UpdateTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.CrudPerson

  # IntegrationCase gives a MODULE-scoped throwaway DB with no per-test reset. Tests
  # here CREATE rows (u1, k1/k2, dup...) with no unique index on id, so without cleanup
  # the "renaming a writable PK" test (which asserts a repo-wide `length(all) == 1`)
  # would see rows leaked by sibling tests and flake under ExUnit's random order.
  # Delete all CrudPerson after each test so every test starts from a clean DB. By
  # cleanup time the vertex type exists, so MATCH never errors on an undefined type.
  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CrudPerson) DETACH DELETE n") end)
    :ok
  end

  defp create(attrs), do: CrudPerson |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!()

  defp stale_record?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale_record?(%{errors: errors}), do: Enum.any?(errors, &stale_record?/1)
  defp stale_record?(_), do: false

  defp update_failed?(%AshArcadic.Errors.UpdateFailed{}), do: true
  defp update_failed?(%{errors: errors}), do: Enum.any?(errors, &update_failed?/1)
  defp update_failed?(_), do: false

  test "update persists changed attributes and returns the updated record" do
    p = create(%{id: "u1", name: "A", age: 1})
    {:ok, updated} = p |> Ash.Changeset.for_update(:update, %{name: "B", age: 2}) |> Ash.update()
    assert updated.name == "B"
    assert updated.age == 2
  end

  test "TRIPWIRE: renaming a writable PK matches on the ORIGINAL key (get_data), not the pending one" do
    p = create(%{id: "k1", name: "A"})

    {:ok, updated} =
      p |> Ash.Changeset.for_update(:update, %{id: "k2", name: "B"}) |> Ash.update()

    assert updated.id == "k2"

    {:ok, all} = CrudPerson |> Ash.Query.new() |> Ash.read()
    assert length(all) == 1, "the k1 row must have been renamed to k2, not left behind"
    assert hd(all).id == "k2"
  end

  test "update whose PK matches no row fails closed as StaleRecord", %{admin: admin} do
    p = create(%{id: "s1", name: "A"})
    Arcadic.command!(admin, "MATCH (n:CrudPerson {id:$id}) DETACH DELETE n", %{"id" => "s1"})

    {:error, error} = p |> Ash.Changeset.for_update(:update, %{name: "B"}) |> Ash.update()
    assert stale_record?(error)
  end

  test "TRIPWIRE: an update matching 2+ rows for one PK fails closed as UpdateFailed (never picks one)",
       %{admin: admin} do
    for _ <- 1..2,
        do:
          Arcadic.command!(admin, "CREATE (n:CrudPerson $p) RETURN n", %{
            "p" => %{"id" => "dup", "name" => "A"}
          })

    {:ok, [rec | _]} = CrudPerson |> Ash.Query.filter(id == "dup") |> Ash.read()
    {:error, error} = rec |> Ash.Changeset.for_update(:update, %{name: "B"}) |> Ash.update()
    assert update_failed?(error)
  end
end
