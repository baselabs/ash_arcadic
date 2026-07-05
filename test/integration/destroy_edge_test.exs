defmodule AshArcadic.Integration.DestroyEdgeTest do
  use AshArcadic.Test.IntegrationCase
  alias AshArcadic.Test.EdgeDestroyPerson

  defp count_edges(admin, from_id, label) do
    {:ok, [%{"c" => c}]} =
      Arcadic.query(admin, "MATCH (a:EDPerson {id:$id})-[e:#{label}]->() RETURN count(e) AS c", %{
        "id" => from_id
      })

    c
  end

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:EDPerson) DETACH DELETE n") end)
    :ok
  end

  test "unfriend removes an existing edge", %{admin: admin} do
    {:ok, a} = create_person("a", "org1")
    {:ok, _} = create_person("b", "org1")
    {:ok, _} = befriend(a, ["b"], "org1")

    assert {:ok, _} = unfriend(a, ["b"], "org1")

    assert count_edges(admin, "a", "KNOWS") == 0
  end

  test "unfriend of an absent edge fails closed as StaleRecord", %{} do
    {:ok, a} = create_person("a", "org1")
    {:ok, _} = create_person("b", "org1")
    # no edge exists
    assert {:error, %Ash.Error.Invalid{errors: errors}} = unfriend(a, ["b"], "org1")
    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  test "cross-tenant unfriend is denied (StaleRecord — wrong tenant can't delete)", %{
    admin: admin
  } do
    {:ok, a1} = create_person("a", "org1")
    {:ok, _} = create_person("b", "org1")
    {:ok, _} = befriend(a1, ["b"], "org1")

    # org2 actor with the same source id must not delete org1's edge.
    {:ok, a2} = create_person("a", "org2")
    assert {:error, %Ash.Error.Invalid{errors: errors}} = unfriend(a2, ["b"], "org2")
    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

    # org1's edge must SURVIVE the denied cross-tenant delete
    {:ok, [%{"c" => c}]} =
      Arcadic.query(
        admin,
        "MATCH (:EDPerson {id:'a', tenant:'org1'})-[e:KNOWS]->() RETURN count(e) AS c",
        %{}
      )

    assert c == 1
  end

  defp create_person(id, tenant) do
    EdgeDestroyPerson
    |> Ash.Changeset.for_create(:create, %{id: id, name: id, tenant: tenant}, tenant: tenant)
    |> Ash.create()
  end

  defp befriend(actor, to, tenant) do
    actor
    |> Ash.Changeset.for_update(:befriend, %{to: to}, tenant: tenant)
    |> Ash.update()
  end

  defp unfriend(actor, to, tenant) do
    actor
    |> Ash.Changeset.for_update(:unfriend, %{to: to}, tenant: tenant)
    |> Ash.update()
  end
end
