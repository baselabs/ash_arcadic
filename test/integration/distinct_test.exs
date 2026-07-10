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
    # Cross-tenant tripwire: org2's Ada(100) also passes amount>6 — any leak into the
    # org1 read yields amounts [100, 9] or a 100 representative → red.
    seed_attr("org2", [{"b1", "Ada", 100}])

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

  test "with no distinct_sort, the representative falls back to the QUERY sort (Ash contract)" do
    # Seed order puts the amount:1 Ada FIRST — an insertion-order representative (the
    # pre-fix `‖ distinct` render) returns {"Ada", 1} here (closeout smoke lens repro);
    # the Ash contract (deps/ash query.ex:4285) requires the query sort to select it.
    seed_attr("org1", [{"a1", "Ada", 1}, {"a2", "Ada", 9}, {"a3", "Bo", 5}])

    rows =
      AttributeDoc
      |> Ash.Query.distinct([:name])
      |> Ash.Query.sort(amount: :desc)
      |> Ash.read!(tenant: "org1", authorize?: false)

    assert Enum.map(rows, &{&1.name, &1.amount}) == [{"Ada", 9}, {"Bo", 5}]
  end

  test "rows whose distinct field is NULL form one group and survive as one representative" do
    # ArcadeDB groups null keys like any other value (closeout probe): 2 null-amount rows
    # collapse to ONE representative; they never silently vanish from the result.
    seed_attr("org1", [{"a1", "Ada", nil}, {"a2", "Bo", nil}, {"a3", "Cy", 7}])

    rows =
      AttributeDoc
      |> Ash.Query.distinct([:amount])
      |> Ash.read!(tenant: "org1", authorize?: false)

    assert length(rows) == 2
    assert Enum.count(rows, &is_nil(&1.amount)) == 1
    assert Enum.count(rows, &(&1.amount == 7)) == 1
  end

  test "distinct_sort honors nil-placement qualifiers inside the representative ORDER BY" do
    # :asc_nils_first renders the `(n.amount IS NULL) DESC` prefix key INSIDE the inner
    # `WITH n ORDER BY` (the D12 probe covered the final RETURN's ORDER BY; this pins the
    # WITH-stage composition live): the null-amount Ada must win representative selection.
    seed_attr("org1", [{"a1", "Ada", 9}, {"a2", "Ada", nil}])

    rows =
      AttributeDoc
      |> Ash.Query.distinct([:name])
      |> Ash.Query.distinct_sort([{:amount, :asc_nils_first}])
      |> Ash.read!(tenant: "org1", authorize?: false)

    assert [%{name: "Ada", amount: nil}] = rows
  end

  test "an expression outer ORDER BY composes after the collect-group re-binding of n (raw probe)",
       %{admin: admin} do
    # The record-read sort path can emit `{:expr, cypher, dir}` fragments; this pins that an
    # expression key referencing the re-bound `n` parses and orders AFTER the collect stage.
    seed_attr("org1", [{"a1", "Ada", 1}, {"a2", "Ada", 9}, {"a3", "Bo", 5}])

    rows =
      Arcadic.query!(
        admin,
        "MATCH (n:AttributeDoc) WHERE n.org_id = $t WITH n ORDER BY n.amount DESC " <>
          "WITH n.name AS __d0, collect(n)[0] AS n RETURN n ORDER BY (n.amount + 1) ASC",
        %{"t" => "org1"}
      )

    # Rows decode as flat vertex maps (RETURN n → %{"@rid" => …, <props>}).
    assert Enum.map(rows, &{&1["name"], &1["amount"]}) == [{"Bo", 5}, {"Ada", 9}]
  end

  test "Ash.count and page count over a distinct query count the DEDUPED representatives" do
    seed_attr("org1", [{"a1", "Ada", 1}, {"a2", "Ada", 9}, {"a3", "Bo", 5}])

    assert AttributeDoc
           |> Ash.Query.distinct([:name])
           |> Ash.count!(tenant: "org1", authorize?: false) == 2

    page =
      AttributeDoc
      |> Ash.Query.distinct([:name])
      |> Ash.read!(tenant: "org1", authorize?: false, page: [limit: 10, count: true])

    assert length(page.results) == 2
    assert page.count == 2
  end

  test "value aggregates over a distinct query fold the representatives, not the raw rows" do
    seed_attr("org1", [{"a1", "Ada", 1}, {"a2", "Ada", 9}, {"a3", "Bo", 5}])

    q =
      AttributeDoc
      |> Ash.Query.distinct([:name])
      |> Ash.Query.distinct_sort(amount: :desc)

    # Representatives are {Ada,9} and {Bo,5}: sum = 14. The pre-dedup fold would return 15
    # (and count 3) — the aggregate must run over the collect-group pipeline, not raw rows.
    assert Ash.sum!(q, :amount, tenant: "org1", authorize?: false) == 14
  end
end
