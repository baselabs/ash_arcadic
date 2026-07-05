defmodule AshArcadic.Integration.DestroyTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.CrudPerson

  defp create(attrs), do: CrudPerson |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!()

  defp stale_record?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale_record?(%{errors: errors}), do: Enum.any?(errors, &stale_record?/1)
  defp stale_record?(_), do: false

  test "destroy deletes the record" do
    p = create(%{id: "d1", name: "A"})
    assert :ok = p |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy()
    {:ok, all} = CrudPerson |> Ash.Query.filter(id == "d1") |> Ash.read()
    assert all == []
  end

  test "destroy of an already-gone record fails closed as StaleRecord (never reports false success)",
       %{admin: admin} do
    p = create(%{id: "d2", name: "A"})
    Arcadic.command!(admin, "MATCH (n:CrudPerson {id:$id}) DETACH DELETE n", %{"id" => "d2"})

    {:error, error} = p |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy()
    assert stale_record?(error)
  end
end
