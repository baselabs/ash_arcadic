defmodule AshArcadic.Integration.CreateEdgeTest do
  use AshArcadic.Test.IntegrationCase
  alias AshArcadic.Test.EdgeWritePerson

  defp count_edges(admin, from_id, label) do
    {:ok, [%{"c" => c}]} =
      Arcadic.query(admin, "MATCH (a:EWPerson {id:$id})-[e:#{label}]->() RETURN count(e) AS c", %{
        "id" => from_id
      })

    c
  end

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:EWPerson) DETACH DELETE n") end)
    :ok
  end

  test "MERGE idempotency: two befriends of the same dest → 1 edge, ON MATCH updates props", %{
    admin: admin
  } do
    {:ok, a} = create_person("a", "org1")
    {:ok, _b} = create_person("b", "org1")

    {:ok, _} = befriend(a, ["b"], "2020", "org1")
    {:ok, _} = befriend(a, ["b"], "2021", "org1")

    assert count_edges(admin, "a", "KNOWS") == 1

    {:ok, [%{"since" => since}]} =
      Arcadic.query(
        admin,
        "MATCH (:EWPerson {id:'a'})-[e:KNOWS]->(:EWPerson {id:'b'}) RETURN e.since AS since",
        %{}
      )

    assert since == "2021"
  end

  test "cross-tenant hijack: a same-PK dest in BOTH tenants — MERGE binds only the in-tenant node",
       %{admin: admin} do
    Arcadic.command!(
      admin,
      "CREATE (n:EWPerson {id:'victim', tenant:'org2', name:'org2-victim'})"
    )

    {:ok, a} = create_person("a", "org1")

    assert {:error, _} = befriend(a, ["victim"], nil, "org1")
    assert count_edges(admin, "a", "KNOWS") == 0

    {:ok, _} = create_person("victim", "org1")
    {:ok, _} = befriend(a, ["victim"], nil, "org1")

    {:ok, [%{"t" => t}]} =
      Arcadic.query(
        admin,
        "MATCH (:EWPerson {id:'a'})-[:KNOWS]->(b:EWPerson {id:'victim'}) RETURN b.tenant AS t",
        %{}
      )

    assert t == "org1"
  end

  test "mid-list failure rolls ALL edges back (0 edges, not partial)", %{admin: admin} do
    {:ok, a} = create_person("a", "org1")
    {:ok, _} = create_person("b", "org1")
    assert {:error, _} = befriend(a, ["b", "ghost"], nil, "org1")
    assert count_edges(admin, "a", "KNOWS") == 0
  end

  defp create_person(id, tenant) do
    EdgeWritePerson
    |> Ash.Changeset.for_create(:create, %{id: id, name: id, tenant: tenant}, tenant: tenant)
    |> Ash.create()
  end

  defp befriend(actor_record, to_ids, since, tenant) do
    actor_record
    |> Ash.Changeset.for_update(:befriend, %{to: to_ids, since: since}, tenant: tenant)
    |> Ash.update()
  end
end
