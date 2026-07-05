defmodule AshArcadic.Integration.TraverseTest do
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Multitenancy
  alias AshArcadic.Test.{TraverseAttrNode, TraverseContextNode}

  # :attribute shares the base DB; wipe the traversal label after each test.
  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:TravAttrNode) DETACH DELETE n") end)
    :ok
  end

  defp create_attr(id, org, name) do
    {:ok, rec} =
      TraverseAttrNode
      |> Ash.Changeset.for_create(:create, %{id: id, name: name}, tenant: org)
      |> Ash.create()

    rec
  end

  defp attr_edge(admin, from, to) do
    Arcadic.command!(
      admin,
      "MATCH (a:TravAttrNode{id:'#{from}'}),(b:TravAttrNode{id:'#{to}'}) " <>
        "CREATE (a)-[:PARENT_OF]->(b)"
    )
  end

  test "TRIPWIRE: :attribute traversal scopes EVERY path node — mis-tenanted nodes at depth 1/2/3 excluded; in-tenant chain kept",
       %{admin: admin} do
    # org1 chain p1->p2->p3->p4 ; org2 branches hanging off each depth.
    p1 = create_attr("p1", "org1", "P1")
    for {id, n} <- [{"p2", "P2"}, {"p3", "P3"}, {"p4", "P4"}], do: create_attr(id, "org1", n)
    for {id, n} <- [{"y1", "Y1"}, {"x2", "X2"}, {"x3", "X3"}], do: create_attr(id, "org2", n)

    attr_edge(admin, "p1", "p2")
    attr_edge(admin, "p2", "p3")
    attr_edge(admin, "p3", "p4")
    attr_edge(admin, "p1", "y1")
    attr_edge(admin, "p2", "x2")
    attr_edge(admin, "p3", "x3")

    {:ok, loaded} = Ash.load(p1, :descendants, tenant: "org1")
    names = loaded.descendants |> Enum.map(& &1.name) |> Enum.sort()

    # Positive control: the whole in-tenant chain is reachable (query is NOT vacuously empty).
    assert names == ["P2", "P3", "P4"]

    # Non-vacuity per depth: NO org2 node at depth 1 (y1), 2 (x2), or 3 (x3).
    refute "Y1" in names
    refute "X2" in names
    refute "X3" in names
  end

  test "TRIPWIRE: a fabricated wrong-tenant load returns nothing (the SEED node is scoped too)",
       %{admin: admin} do
    p1 = create_attr("p1", "org1", "P1")
    create_attr("p2", "org1", "P2")
    attr_edge(admin, "p1", "p2")

    # Sanity: the correct tenant sees the child (proves the graph + edge exist).
    {:ok, ok} = Ash.load(p1, :descendants, tenant: "org1")
    assert Enum.map(ok.descendants, & &1.name) == ["P2"]

    # Fabricated attacker: a struct with NO metadata tenant, so `tenant: "org2"` sticks
    # (a record LOADED under org1 carries __metadata__.tenant, which would override).
    # p1's stored org_id is "org1" → fails ALL(nodes(p)) under org2 → 0 rows.
    fabricated = struct(TraverseAttrNode, id: "p1", org_id: "org1", name: "P1")
    {:ok, denied} = Ash.load(fabricated, :descendants, tenant: "org2")
    assert denied.descendants == []
  end

  test ":context traversal is physically scoped to the tenant database", %{admin: admin} do
    t = "torg_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    db = Multitenancy.database_name(TraverseContextNode, t)
    Arcadic.Server.create_database!(admin, db)
    on_exit(fn -> Arcadic.Server.drop_database(admin, db) end)
    tconn = Arcadic.with_database(admin, db)

    {:ok, n1} =
      TraverseContextNode
      |> Ash.Changeset.for_create(:create, %{id: "n1", name: "N1"}, tenant: t)
      |> Ash.create()

    for {id, n} <- [{"n2", "N2"}, {"n3", "N3"}, {"n4", "N4"}] do
      {:ok, _} =
        TraverseContextNode
        |> Ash.Changeset.for_create(:create, %{id: id, name: n}, tenant: t)
        |> Ash.create()
    end

    for {from, to} <- [{"n1", "n2"}, {"n2", "n3"}, {"n3", "n4"}] do
      Arcadic.command!(
        tconn,
        "MATCH (a:TravCtxNode{id:'#{from}'}),(b:TravCtxNode{id:'#{to}'}) " <>
          "CREATE (a)-[:PARENT_OF]->(b)"
      )
    end

    {:ok, loaded} = Ash.load(n1, :descendants, tenant: t)
    assert loaded.descendants |> Enum.map(& &1.name) |> Enum.sort() == ["N2", "N3", "N4"]
  end
end
