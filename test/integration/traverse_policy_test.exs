defmodule AshArcadic.Integration.TraversePolicyTest do
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Multitenancy
  alias AshArcadic.Test.{TraversePolicyContextNode, TraversePolicyNode}

  require Ash.Query

  @admin %{admin: true}
  @user %{admin: false}

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

  defp create_strict(id, org, name, visible, strict_ok) do
    {:ok, rec} =
      TraversePolicyNode
      |> Ash.Changeset.for_create(
        :create,
        %{id: id, name: name, visible: visible, strict_ok: strict_ok},
        tenant: org
      )
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

  test "TRIPWIRE (Challenge-1): a row-policy-denied destination is DROPPED even on the PK-only load",
       %{admin: admin} do
    p1 = create_attr("p1", "org1", "P1", true)
    create_attr("ok", "org1", "OK", true)
    create_attr("secret", "org1", "SECRET", false)
    pol_edge(admin, "p1", "ok", "org1")
    pol_edge(admin, "p1", "secret", "org1")

    # Non-admin, authorize?: true — the traversal's Option-B read applies the row policy.
    {:ok, loaded} = Ash.load(p1, :descendants, tenant: "org1", actor: @user, authorize?: true)
    names = loaded.descendants |> Enum.map(& &1.name) |> Enum.sort()

    # Positive control: the visible dest IS reachable + authorized (not vacuously empty).
    assert names == ["OK"]
    # The reachable-but-policy-denied dest is dropped by the authorized read.
    refute "SECRET" in names

    # Non-vacuity: with authorize?: false the SAME reachable graph returns BOTH (proves the
    # denial is the policy, not the graph).
    {:ok, unauth} = Ash.load(p1, :descendants, tenant: "org1", actor: @user, authorize?: false)
    assert unauth.descendants |> Enum.map(& &1.name) |> Enum.sort() == ["OK", "SECRET"]
  end

  test "PER-HOP: a destination reachable only through a row-policy-denied INTERMEDIATE is dropped; an authorized multi-hop path survives",
       %{admin: admin} do
    # p1 -> mid(DENIED) -> leaf(visible)   : leaf reachable ONLY via denied mid
    # p1 -> ok(visible) -> deep(visible)    : deep reachable via a fully-authorized path
    p1 = create_attr("p1", "org1", "P1", true)
    create_attr("mid", "org1", "MID", false)
    create_attr("leaf", "org1", "LEAF", true)
    create_attr("ok", "org1", "OK", true)
    create_attr("deep", "org1", "DEEP", true)
    pol_edge(admin, "p1", "mid", "org1")
    pol_edge(admin, "mid", "leaf", "org1")
    pol_edge(admin, "p1", "ok", "org1")
    pol_edge(admin, "ok", "deep", "org1")

    {:ok, loaded} = Ash.load(p1, :descendants, tenant: "org1", actor: @user, authorize?: true)
    names = loaded.descendants |> Enum.map(& &1.name) |> Enum.sort()

    # OK (direct) + DEEP (authorized 2-hop path) survive; MID denied; LEAF dropped because its
    # ONLY path crosses the denied MID. This distinguishes per-hop authz from "drop past depth 1".
    assert names == ["DEEP", "OK"]
    refute "MID" in names
    refute "LEAF" in names

    # Non-vacuity: authorize?: false traverses the same graph unrestricted → all four appear
    # (proves LEAF's exclusion is the intermediate policy, not the graph shape).
    {:ok, unauth} = Ash.load(p1, :descendants, tenant: "org1", actor: @user, authorize?: false)

    assert unauth.descendants |> Enum.map(& &1.name) |> Enum.sort() == [
             "DEEP",
             "LEAF",
             "MID",
             "OK"
           ]
  end

  test "PER-HOP under a configured read_action: an intermediate denied by the stricter action drops the downstream dest",
       %{admin: admin} do
    # descendants_strict reads via :strict (requires visible AND strict_ok). `mid` passes the
    # PRIMARY :read (visible) but FAILS :strict (strict_ok:false). Read A must authorize
    # intermediates under :strict — the SAME action Read B uses — so `leaf` (reachable ONLY via
    # mid) is dropped. (A Read A that used the primary :read would authorize mid → leak leaf.)
    p1 = create_attr("p1", "org1", "P1", true)
    create_strict("mid", "org1", "MID", true, false)
    create_attr("leaf", "org1", "LEAF", true)
    create_attr("ok", "org1", "OK", true)
    pol_edge(admin, "p1", "mid", "org1")
    pol_edge(admin, "mid", "leaf", "org1")
    pol_edge(admin, "p1", "ok", "org1")

    {:ok, loaded} =
      Ash.load(p1, :descendants_strict, tenant: "org1", actor: @user, authorize?: true)

    names = loaded.descendants_strict |> Enum.map(& &1.name) |> Enum.sort()

    # OK survives; MID denied by :strict; LEAF dropped (its only path crosses the :strict-denied MID).
    assert names == ["OK"]
    refute "LEAF" in names

    # Non-vacuity: authorize?: false traverses unrestricted → LEAF + MID reappear.
    {:ok, unauth} =
      Ash.load(p1, :descendants_strict, tenant: "org1", actor: @user, authorize?: false)

    assert "LEAF" in (unauth.descendants_strict |> Enum.map(& &1.name))
  end

  test "a caller FILTER selects destinations but does NOT block traversal through a filtered-out (but authorized) intermediate",
       %{admin: admin} do
    # p1 -> hide -> deep : `deep` reachable ONLY through `hide`. `hide` is AUTHORIZED (visible)
    # but excluded by the caller filter `name != "HIDE"`. Per-hop authz must gate intermediates
    # by ROW POLICY, not by the caller's destination filter — so the filter drops `hide` from the
    # RESULTS without blocking traversal THROUGH it to `deep`.
    p1 = create_attr("p1", "org1", "P1", true)
    create_attr("hide", "org1", "HIDE", true)
    create_attr("deep", "org1", "DEEP", true)
    create_attr("keep", "org1", "KEEP", true)
    pol_edge(admin, "p1", "hide", "org1")
    pol_edge(admin, "hide", "deep", "org1")
    pol_edge(admin, "p1", "keep", "org1")

    filtered = Ash.Query.filter(TraversePolicyNode, name != "HIDE")

    {:ok, loaded} =
      Ash.load(p1, [descendants: filtered], tenant: "org1", actor: @user, authorize?: true)

    names = loaded.descendants |> Enum.map(& &1.name) |> Enum.sort()
    # DEEP survives (traversed through the visible HIDE); KEEP direct; HIDE filtered from results.
    assert names == ["DEEP", "KEEP"]
    refute "HIDE" in names
  end

  test "a caller filter on the loaded relationship is honored (Option-B delegates filter to the read)",
       %{admin: admin} do
    p1 = create_attr("p1", "org1", "P1", true)
    create_attr("keep", "org1", "KEEP", true)
    create_attr("hide", "org1", "HIDE", true)
    pol_edge(admin, "p1", "keep", "org1")
    pol_edge(admin, "p1", "hide", "org1")

    filtered = Ash.Query.filter(TraversePolicyNode, name != "HIDE")

    {:ok, loaded} =
      Ash.load(p1, [descendants: filtered], tenant: "org1", actor: @admin, authorize?: true)

    names = loaded.descendants |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["KEEP"]
    refute "HIDE" in names
  end

  test ":context matrix — the two-phase read is policy-correct under physical DB isolation too",
       %{admin: admin} do
    t = "ptorg_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    db = Multitenancy.database_name(TraversePolicyContextNode, t)
    Arcadic.Server.create_database!(admin, db)
    on_exit(fn -> Arcadic.Server.drop_database(admin, db) end)
    tconn = Arcadic.with_database(admin, db)

    {:ok, p1} =
      TraversePolicyContextNode
      |> Ash.Changeset.for_create(:create, %{id: "p1", name: "P1", visible: true}, tenant: t)
      |> Ash.create(actor: @admin)

    for {id, n, v} <- [{"ok", "OK", true}, {"secret", "SECRET", false}] do
      {:ok, _} =
        TraversePolicyContextNode
        |> Ash.Changeset.for_create(:create, %{id: id, name: n, visible: v}, tenant: t)
        |> Ash.create(actor: @admin)
    end

    for {from, to} <- [{"p1", "ok"}, {"p1", "secret"}] do
      Arcadic.command!(
        tconn,
        "MATCH (a:TravPolCtxNode{id:'#{from}'}),(b:TravPolCtxNode{id:'#{to}'}) " <>
          "CREATE (a)-[:POL_PARENT_OF]->(b)"
      )
    end

    {:ok, loaded} = Ash.load(p1, :descendants, tenant: t, actor: @user, authorize?: true)
    assert loaded.descendants |> Enum.map(& &1.name) |> Enum.sort() == ["OK"]
  end
end
