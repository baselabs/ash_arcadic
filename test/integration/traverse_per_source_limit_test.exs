defmodule AshArcadic.Integration.TraversePerSourceLimitTest do
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Test.TraversePolicyNode

  require Ash.Query

  @admin %{admin: true}
  @user %{admin: false}

  # Topology for BOTH tests is a FAN-OUT STAR within ONE tenant `org1`:
  #   s1 -POL_PARENT_OF-> d1, d2, d3, d4, d5   (five single-hop paths)
  #   s2 -POL_PARENT_OF-> e1                    (one single-hop path)
  # WHY a star (and not a chain): per-hop authorization requires EVERY node on a
  # destination's path to be authorized. In a star every dest is a single-hop path of its
  # own, so denying d1 drops ONLY d1's path and leaves d2..d5 independently reachable. A
  # CHAIN could not isolate "a denied sibling does not consume a top-N slot" from "a denied
  # intermediate nukes everything downstream" — the two would be indistinguishable.

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:TravPolNode) DETACH DELETE n") end)
    :ok
  end

  defp create_attr(id, org, name, visible) do
    {:ok, rec} =
      TraversePolicyNode
      |> Ash.Changeset.for_create(:create, %{id: id, name: name, visible: visible}, tenant: org)
      |> Ash.create(actor: @admin)

    rec
  end

  defp pol_edge(admin, from, to, org) do
    Arcadic.command!(
      admin,
      "MATCH (a:TravPolNode{id:'#{from}'}),(b:TravPolNode{id:'#{to}'}) " <>
        "CREATE (a)-[:POL_PARENT_OF{org_id:'#{org}'}]->(b)"
    )
  end

  # Seeds the fan-out star (s1 -> d1..d5, s2 -> e1) with the given per-node visibility for
  # d1, returning {s1, s2}. Every node + edge is stamped org1. d2..d5, s1, s2, e1 are always
  # visible; only d1's visibility varies (all-visible in Test A, denied in Test B).
  defp seed_star(admin, d1_visible) do
    s1 = create_attr("s1", "org1", "S1", true)
    s2 = create_attr("s2", "org1", "S2", true)
    create_attr("d1", "org1", "D1", d1_visible)
    create_attr("d2", "org1", "D2", true)
    create_attr("d3", "org1", "D3", true)
    create_attr("d4", "org1", "D4", true)
    create_attr("d5", "org1", "D5", true)
    create_attr("e1", "org1", "E1", true)

    for d <- ~w(d1 d2 d3 d4 d5), do: pol_edge(admin, "s1", d, "org1")
    pol_edge(admin, "s2", "e1", "org1")

    {s1, s2}
  end

  test "each source returns at most N by the relationship sort (non-vacuous)", %{admin: admin} do
    # Star, ALL nodes visible. Load unrestricted (@admin bypasses the visible policy) so this
    # test isolates the LIMIT from any policy interaction.
    {s1, s2} = seed_star(admin, true)

    {:ok, [s1, s2]} =
      Ash.load([s1, s2], :descendants_top2, tenant: "org1", actor: @admin, authorize?: true)

    # s1 has 5 reachable dests; sort(id: :asc) + per_source_limit 2 → top-2 = [d1, d2].
    assert Enum.map(s1.descendants_top2, & &1.id) == ["d1", "d2"]
    # s2 has 1 reachable dest (< limit) → survives untouched.
    assert length(s2.descendants_top2) == 1
    assert Enum.map(s2.descendants_top2, & &1.id) == ["e1"]

    # MUTATION PROOF (non-vacuity): the SAME traversal WITHOUT a per_source_limit (the existing
    # `descendants` relationship) returns all 5 for s1. Proves the cap to 2 is the LIMIT, not the
    # graph shape.
    {:ok, s1_all} = Ash.load(s1, :descendants, tenant: "org1", actor: @admin, authorize?: true)
    assert length(s1_all.descendants) == 5
  end

  test "the per-source limit is applied POST-authorization (a denied sibling does not consume a slot)",
       %{admin: admin} do
    # Same star, but d1 is visible:false → DENIED for @user under authorize?: true.
    {s1, _s2} = seed_star(admin, false)

    {:ok, s1} =
      Ash.load(s1, :descendants_top2, tenant: "org1", actor: @user, authorize?: true)

    # Authorized reachable (id asc) = d2, d3, d4, d5 (d1 denied). per_source_limit 2 applied
    # POST-authz + POST-sort → [d2, d3]. This is the SECURITY-CRITICAL assertion: if the slice
    # were PRE-authz / DB-side, the reachability top-2 would be [d1, d2], authz would then drop
    # d1 → [d2] (only ONE). Asserting [d2, d3] proves the top-N slice runs AFTER authorization.
    assert Enum.map(s1.descendants_top2, & &1.id) == ["d2", "d3"]
    refute "d1" in Enum.map(s1.descendants_top2, & &1.id)

    # NON-VACUITY: load the SAME graph as @admin (policy bypass) — d1 reappears and the
    # unrestricted top-2 is [d1, d2], proving d1's exclusion under @user is the POLICY, not the
    # graph.
    {:ok, s1_admin} =
      Ash.load(s1, :descendants_top2, tenant: "org1", actor: @admin, authorize?: true)

    assert Enum.map(s1_admin.descendants_top2, & &1.id) == ["d1", "d2"]
    assert "d1" in Enum.map(s1_admin.descendants_top2, & &1.id)
  end
end
