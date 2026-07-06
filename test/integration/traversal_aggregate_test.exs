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

    # Loaded with actor: @admin (policy BYPASS) → proves the aggregate COMPUTE is correct over the
    # full subtree. The two tests below prove per-hop AUTHZ enforcement and tenant isolation.
    {:ok, s} = Ash.load(s, :descendant_count, tenant: "org1", actor: @admin, authorize?: true)
    assert s.descendant_count == 3
  end

  @user %{admin: false}

  # s -> a(visible) ; s -> mid(visible:false, DENIED for @user) -> deep(visible)
  # Authorized subtree for @user: {a} only (mid denied → deep unreachable). count = 1.
  # For @admin (policy bypass): {a, mid, deep} → count = 3.
  # mid is a true INTERMEDIATE (s->mid->deep), not a denied leaf — required so the test distinguishes
  # full-path per-hop scoping from endpoint-only scoping.
  defp seed_denied_intermediate(admin) do
    s = create("s", "org1", "S", true)
    create("a", "org1", "A", true)
    create("mid", "org1", "MID", false)
    create("deep", "org1", "DEEP", true)
    edge(admin, "s", "a", "org1")
    edge(admin, "s", "mid", "org1")
    edge(admin, "mid", "deep", "org1")
    s
  end

  test "per-hop authz: a denied INTERMEDIATE drops its subtree from the aggregate (mutation-proven)",
       %{admin: admin} do
    s = seed_denied_intermediate(admin)

    {:ok, s_user} = Ash.load(s, :descendant_count, tenant: "org1", actor: @user, authorize?: true)

    # SECURITY-CRITICAL: mid denied → deep unreachable → only `a` counts. NOT 3 (which a DB-side
    # or authorize?:false aggregate would return by counting mid+deep).
    assert s_user.descendant_count == 1

    {:ok, s_admin} =
      Ash.load(s, :descendant_count, tenant: "org1", actor: @admin, authorize?: true)

    # NON-VACUITY: @admin bypasses the policy → all 3 counted, proving the exclusion is POLICY,
    # not graph shape.
    assert s_admin.descendant_count == 3
  end

  test "tenant isolation: a cross-tenant node is not counted", %{admin: admin} do
    s = create("s", "org1", "S", true)
    create("a", "org1", "A", true)
    create("x", "org2", "X", true)
    edge(admin, "s", "a", "org1")
    edge(admin, "s", "x", "org2")

    {:ok, s} = Ash.load(s, :descendant_count, tenant: "org1", actor: @admin, authorize?: true)
    assert s.descendant_count == 1
  end
end
