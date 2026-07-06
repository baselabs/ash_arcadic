defmodule AshArcadic.Integration.TraversalAggregateTest do
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Test.TraversePolicyNode

  @admin %{admin: true}

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:TravPolNode) DETACH DELETE n") end)
    :ok
  end

  defp create(id, org, name, visible) do
    {:ok, r} =
      TraversePolicyNode
      |> Ash.Changeset.for_create(:create, %{id: id, name: name, visible: visible}, tenant: org)
      |> Ash.create(actor: @admin)

    r
  end

  defp edge(admin, from, to, org) do
    Arcadic.command!(
      admin,
      "MATCH (a:TravPolNode{id:'#{from}'}),(b:TravPolNode{id:'#{to}'}) " <>
        "CREATE (a)-[:POL_PARENT_OF{org_id:'#{org}'}]->(b)"
    )
  end

  # Tree in org1: s -> c1,c2 ; c1 -> g1 (so s reaches c1,c2,g1 = 3 descendants).
  defp seed_tree(admin) do
    s = create("s", "org1", "S", true)
    for {id, nm} <- [{"c1", "C1"}, {"c2", "C2"}, {"g1", "G1"}], do: create(id, "org1", nm, true)
    edge(admin, "s", "c1", "org1")
    edge(admin, "s", "c2", "org1")
    edge(admin, "c1", "g1", "org1")
    s
  end

  test "descendant_count aggregate loads per-record over the authorized subtree", %{admin: admin} do
    s = seed_tree(admin)
    {:ok, s} = Ash.load(s, :descendant_count, tenant: "org1", actor: @admin, authorize?: true)
    assert s.descendant_count == 3
  end
end
