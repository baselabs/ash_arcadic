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
