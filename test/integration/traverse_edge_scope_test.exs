defmodule AshArcadic.Integration.TraverseEdgeScopeTest do
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Test.TraverseAttrNode

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

  # Stamp the edge's org_id (a "library-written" edge carries the tenant discriminator, §6).
  defp attr_edge(admin, from, to, org) do
    Arcadic.command!(
      admin,
      "MATCH (a:TravAttrNode{id:'#{from}'}),(b:TravAttrNode{id:'#{to}'}) " <>
        "CREATE (a)-[:PARENT_OF{org_id:'#{org}'}]->(b)"
    )
  end

  # ALL nODES are org1 — only an EDGE is cross-tenant. The org2 edge is a true INTERMEDIATE
  # (p1 -[org2]-> mid -[org1]-> leaf): `leaf` is org1, reachable from p1 ONLY through the org2
  # edge. Full-path ALL(relationships(p)) EXCLUDES leaf; a weaker terminal-edge-only predicate
  # (scope only the final edge into `b`) would WRONGLY INCLUDE it (the final edge mid->leaf is
  # org1). This is the edge analog of the node intermediate-hop memory — it is what lets the
  # edge-scope gate go red for a too-weak predicate.
  test "TRIPWIRE: default-on relationships(p) excludes an in-tenant leaf reachable only through a cross-tenant INTERMEDIATE edge",
       %{admin: admin} do
    create_attr("p1", "org1", "P1")
    create_attr("mid", "org1", "MID")
    create_attr("leaf", "org1", "LEAF")
    create_attr("other", "org1", "OTHER")

    attr_edge(admin, "p1", "mid", "org2")
    attr_edge(admin, "mid", "leaf", "org1")
    attr_edge(admin, "p1", "other", "org1")

    p1 = struct(TraverseAttrNode, id: "p1", org_id: "org1", name: "P1")
    {:ok, loaded} = Ash.load(p1, :descendants, tenant: "org1")
    names = loaded.descendants |> Enum.map(& &1.name) |> Enum.sort()

    # Positive control: the all-org1-edge path p1 -[org1]-> other IS reachable (not vacuous).
    assert "OTHER" in names
    # mid + leaf reached only through the org2 edge p1->mid → excluded by ALL(relationships(p)).
    refute "MID" in names
    refute "LEAF" in names
  end

  test "scope_edges: false opt-out re-includes the cross-tenant-edge path (proves the predicate is what excludes it)",
       %{admin: admin} do
    create_attr("p1", "org1", "P1")
    create_attr("mid", "org1", "MID")
    create_attr("leaf", "org1", "LEAF")

    attr_edge(admin, "p1", "mid", "org2")
    attr_edge(admin, "mid", "leaf", "org1")

    p1 = struct(TraverseAttrNode, id: "p1", org_id: "org1", name: "P1")
    {:ok, loaded} = Ash.load(p1, :descendants_unscoped_edges, tenant: "org1")
    names = loaded.descendants_unscoped_edges |> Enum.map(& &1.name) |> Enum.sort()

    # Edges unscoped, all NODES org1 → the org2-edge path is traversed; mid + leaf included.
    assert "MID" in names
    assert "LEAF" in names
  end
end
