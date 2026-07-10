defmodule AshArcadic.Integration.DistinctTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Multitenancy
  alias AshArcadic.Test.{AttributeDoc, ContextDoc}

  # :context needs its per-tenant DBs provisioned; :attribute shares the base DB (scoped by org_id)
  # so every AttributeDoc is DETACH DELETE'd after each test to stop org bleed across tests.
  setup %{admin: admin} do
    t_ctx = "dist_ctx_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
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

  test "distinct on :name dedups within a tenant (native collect-group), representative by distinct_sort" do
    # org1: two "Ada" rows (amount 1, 9) + one "Bo"; distinct :name → 2 rows; distinct_sort amount desc
    # picks the amount:9 Ada.
    seed_attr("org1", [{"a1", "Ada", 1}, {"a2", "Ada", 9}, {"a3", "Bo", 5}])
    seed_attr("org2", [{"b1", "Ada", 100}])

    rows =
      AttributeDoc
      |> Ash.Query.distinct([:name])
      |> Ash.Query.distinct_sort(amount: :desc)
      |> Ash.read!(tenant: "org1", authorize?: false)

    names = rows |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["Ada", "Bo"]
    # tenant isolation: org2's Ada (amount 100) never appears; the Ada kept is org1's amount:9
    ada = Enum.find(rows, &(&1.name == "Ada"))
    assert ada.amount == 9

    limited =
      AttributeDoc
      |> Ash.Query.distinct([:name])
      |> Ash.Query.distinct_sort(amount: :desc)
      |> Ash.Query.sort(amount: :asc)
      |> Ash.Query.limit(1)
      |> Ash.read!(tenant: "org1", authorize?: false)

    # Outer sort/LIMIT apply AFTER the collect-group: over the representatives
    # {Ada,9} and {Bo,5}, amount asc + limit 1 keeps exactly Bo(5) — a pre-collect
    # sort/limit would instead see the raw rows (amount 1 first) and keep Ada.
    assert Enum.map(limited, &{&1.name, &1.amount}) == [{"Bo", 5}]
  end

  test ":context distinct dedups within the tenant database", %{t_ctx: t_ctx} do
    for {id, name} <- [{"c1", "X"}, {"c2", "X"}, {"c3", "Y"}] do
      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: id, name: name}, tenant: t_ctx)
      |> Ash.create!(authorize?: false)
    end

    rows =
      ContextDoc
      |> Ash.Query.distinct([:name])
      |> Ash.read!(tenant: t_ctx, authorize?: false)

    assert rows |> Enum.map(& &1.name) |> Enum.sort() == ["X", "Y"]
  end

  test "distinct composes with a WHERE filter (applied BEFORE the collect-group), still per-tenant" do
    seed_attr("org1", [{"a1", "Ada", 1}, {"a2", "Ada", 9}, {"a3", "Bo", 5}])

    rows =
      AttributeDoc
      |> Ash.Query.filter(amount: [greater_than: 6])
      |> Ash.Query.distinct([:name])
      |> Ash.read!(tenant: "org1", authorize?: false)

    # amount>6 keeps only {Ada,9}: Bo(5) and the amount:1 Ada are filtered BEFORE the
    # collect-group. A dropped filter yields ["Ada", "Bo"] → red; a filter applied only
    # AFTER an arbitrary dedup could keep Ada(1) → [] → red.
    assert Enum.map(rows, & &1.name) == ["Ada"]
    assert Enum.map(rows, & &1.amount) == [9]
  end
end
