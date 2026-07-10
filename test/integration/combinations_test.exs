defmodule AshArcadic.Integration.CombinationsTest do
  use AshArcadic.Test.IntegrationCase
  @moduletag :integration

  require Ash.Query
  require Ash.Expr
  alias Ash.Query.Combination
  alias AshArcadic.Multitenancy
  alias AshArcadic.Test.{AttributeDoc, ContextDoc}

  setup %{admin: admin} do
    t_ctx = "comb_ctx_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    :ok = Arcadic.Server.create_database!(admin, Multitenancy.database_name(ContextDoc, t_ctx))

    on_exit(fn ->
      Arcadic.command!(admin, "MATCH (n:AttributeDoc) DETACH DELETE n")
      Arcadic.Server.drop_database(admin, Multitenancy.database_name(ContextDoc, t_ctx))
    end)

    {:ok, t_ctx: t_ctx}
  end

  defp seed_attr(tenant, rows) do
    for {id, name, amount} <- rows do
      AttributeDoc
      |> Ash.Changeset.for_create(:create, %{id: id, name: name, amount: amount}, tenant: tenant)
      |> Ash.create!(authorize?: false)
    end
  end

  defp ids(records), do: records |> Enum.map(& &1.id) |> Enum.sort()

  test "native UNION dedups across branches, tenant-scoped (:attribute)" do
    # b is eng AND amount==30, so it is in BOTH branches → UNION must keep it ONCE (length 3);
    # UNION ALL would keep it twice (length 4). This exercises live dedup, not just the operator string.
    seed_attr("org1", [{"a", "eng", 10}, {"b", "eng", 30}, {"c", "ops", 30}])
    seed_attr("org2", [{"z", "eng", 10}])

    q =
      AttributeDoc
      |> Ash.Query.combination_of([
        Combination.base(filter: Ash.Expr.expr(name == "eng")),
        Combination.union(filter: Ash.Expr.expr(amount == 30))
      ])

    records = Ash.read!(q, tenant: "org1", authorize?: false)
    # base(eng)→{a,b}; union(amount==30)→{b,c}; UNION dedups b → {a,b,c}, exactly 3 rows.
    assert ids(records) == ["a", "b", "c"]
    assert length(records) == 3
    refute "z" in ids(records)
  end

  test "native UNION ALL keeps duplicates (:attribute)" do
    seed_attr("org1", [{"a", "eng", 20}, {"b", "eng", 20}])

    q =
      AttributeDoc
      |> Ash.Query.combination_of([
        Combination.base(filter: Ash.Expr.expr(name == "eng")),
        Combination.union_all(filter: Ash.Expr.expr(amount == 20))
      ])

    records = Ash.read!(q, tenant: "org1", authorize?: false)
    assert length(records) == 4
  end

  test "in-memory INTERSECT keeps only rows in both branches, PK-keyed, tenant-scoped" do
    seed_attr("org1", [{"a", "eng", 10}, {"b", "eng", 20}, {"c", "ops", 20}])

    # cross-tenant attacker: org2 row with the SAME id "a" (PK collides across tenants under :attribute)
    seed_attr("org2", [{"a", "eng", 20}])

    q =
      AttributeDoc
      |> Ash.Query.combination_of([
        Combination.base(filter: Ash.Expr.expr(name == "eng")),
        Combination.intersect(filter: Ash.Expr.expr(amount == 20))
      ])

    records = Ash.read!(q, tenant: "org1", authorize?: false)

    # org1 eng → {a,b}; org1 amount==20 → {b,c}; INTERSECT → {b}. The org2 "a" (amount 20) must NOT
    # leak into either branch — if per-branch scoping were dropped, the intersect would include "a".
    assert ids(records) == ["b"]
    refute "a" in ids(records)
  end

  test "in-memory EXCEPT removes second-branch rows (:attribute)" do
    seed_attr("org1", [{"a", "eng", 10}, {"b", "eng", 20}, {"c", "ops", 30}])

    q =
      AttributeDoc
      |> Ash.Query.combination_of([
        Combination.base(filter: Ash.Expr.expr(name == "eng")),
        Combination.except(filter: Ash.Expr.expr(amount == 20))
      ])

    records = Ash.read!(q, tenant: "org1", authorize?: false)
    assert ids(records) == ["a"]
  end

  test ":context combination runs within the tenant database", %{t_ctx: t_ctx} do
    for {id, name, amount} <- [{"c1", "x", 1}, {"c2", "y", 2}, {"c3", "z", 3}] do
      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: id, name: name, amount: amount}, tenant: t_ctx)
      |> Ash.create!(authorize?: false)
    end

    q =
      ContextDoc
      |> Ash.Query.combination_of([
        Combination.base(filter: Ash.Expr.expr(amount == 1)),
        Combination.union(filter: Ash.Expr.expr(amount == 3))
      ])

    records = Ash.read!(q, tenant: t_ctx, authorize?: false)
    assert ids(records) == ["c1", "c3"]
  end
end
