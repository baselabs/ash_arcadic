defmodule AshArcadic.Integration.AggregateTest do
  use AshArcadic.Test.IntegrationCase
  @moduletag :integration

  require Ash.Query
  alias AshArcadic.Multitenancy
  alias AshArcadic.Test.{AttributeDoc, ContextDoc}

  # :context = database-per-tenant → provision the tenant DBs (mirrors multitenancy_context_test.exs).
  # :attribute needs no provisioning (single base DB, scoped by org_id). admin comes from IntegrationCase.
  # :attribute shares ONE base DB across every test in this file, so DETACH DELETE all AttributeDoc
  # after each test — otherwise org1/org3/org_pag seeds leak into another test's tenant-scoped count.
  setup %{admin: admin} do
    ta = "agg_a_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    tb = "agg_b_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    for t <- [ta, tb],
        do: Arcadic.Server.create_database!(admin, Multitenancy.database_name(ContextDoc, t))

    on_exit(fn ->
      Arcadic.command!(admin, "MATCH (n:AttributeDoc) DETACH DELETE n")

      for t <- [ta, tb],
          do: Arcadic.Server.drop_database(admin, Multitenancy.database_name(ContextDoc, t))
    end)

    {:ok, ta: ta, tb: tb}
  end

  # :attribute — tenant sets org_id automatically for the :attribute strategy.
  defp seed_attr(tenant, amounts) do
    for {amt, i} <- Enum.with_index(amounts) do
      AttributeDoc
      |> Ash.Changeset.for_create(:create, %{id: "#{tenant}_#{i}", amount: amt}, tenant: tenant)
      |> Ash.create!(authorize?: false)
    end
  end

  defp seed_ctx(tenant, amounts) do
    for {amt, i} <- Enum.with_index(amounts) do
      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: "#{tenant}_#{i}", amount: amt}, tenant: tenant)
      |> Ash.create!(authorize?: false)
    end
  end

  # Rows that exist but leave :amount unset (nil) — an all-null-field set (distinct from empty).
  defp seed_attr_no_amount(tenant, count) do
    for i <- 1..count do
      AttributeDoc
      |> Ash.Changeset.for_create(:create, %{id: "#{tenant}_#{i}"}, tenant: tenant)
      |> Ash.create!(authorize?: false)
    end
  end

  describe "query aggregates over :attribute (tenant-scoped by org_id)" do
    test "count/sum/avg/min/max scoped to caller tenant; cross-tenant EXCLUDED (non-vacuous)" do
      seed_attr("org1", [10, 20, 30])
      seed_attr("org2", [999])

      assert {:ok, 3} == Ash.count(AttributeDoc, tenant: "org1", authorize?: false)
      assert {:ok, 60} == Ash.sum(AttributeDoc, :amount, tenant: "org1", authorize?: false)
      assert {:ok, 10} == Ash.min(AttributeDoc, :amount, tenant: "org1", authorize?: false)
      assert {:ok, 30} == Ash.max(AttributeDoc, :amount, tenant: "org1", authorize?: false)
      assert {:ok, avg} = Ash.avg(AttributeDoc, :amount, tenant: "org1", authorize?: false)
      assert avg in [20, 20.0]
      # MUTATION PROOF: org2's 999 must NOT leak into org1's max/sum (RED if scoping broke).
      refute {:ok, 999} == Ash.max(AttributeDoc, :amount, tenant: "org1", authorize?: false)
      refute {:ok, 1059} == Ash.sum(AttributeDoc, :amount, tenant: "org1", authorize?: false)
    end

    test "empty tenant → count 0, sum nil (Ash default, not ArcadeDB 0 — probe G7)" do
      assert {:ok, 0} == Ash.count(AttributeDoc, tenant: "org_empty", authorize?: false)
      assert {:ok, nil} == Ash.sum(AttributeDoc, :amount, tenant: "org_empty", authorize?: false)
    end

    test "all-null field → Ash default, not raw ArcadeDB value (count(n.<field>) skips nulls)" do
      # Rows exist for the tenant, but :amount is nil in every one. Live-verified: ArcadeDB
      # sum→0, min/max/avg→nil, count(n)→3, count(n.amount)→0. The companion counts NON-NULL
      # field values, so decode applies the Ash default for a no-non-null-values set — matching
      # ash_postgres/ETS (SQL aggregates skip nulls). A count(n) companion would return raw 0/nil.
      seed_attr_no_amount("org_null", 3)

      # count(n) still counts the rows — the fix is scoped to value-reading kinds.
      assert {:ok, 3} == Ash.count(AttributeDoc, tenant: "org_null", authorize?: false)

      # sum over an all-null field → nil (NOT ArcadeDB's 0); a caller default is honored.
      assert {:ok, nil} == Ash.sum(AttributeDoc, :amount, tenant: "org_null", authorize?: false)

      assert {:ok, 0} ==
               Ash.sum(AttributeDoc, :amount, tenant: "org_null", authorize?: false, default: 0)

      # min over an all-null field → nil; caller default honored.
      assert {:ok, nil} == Ash.min(AttributeDoc, :amount, tenant: "org_null", authorize?: false)

      assert {:ok, 7} ==
               Ash.min(AttributeDoc, :amount, tenant: "org_null", authorize?: false, default: 7)
    end

    test "exists? / list / count(uniq?)" do
      seed_attr("org3", [10, 20, 20])
      # Ash.exists?/2 is the unwrapping (bang-style) variant → bare boolean, not {:ok, _}.
      assert Ash.exists?(AttributeDoc, tenant: "org3", authorize?: false) == true
      assert {:ok, list} = Ash.list(AttributeDoc, :amount, tenant: "org3", authorize?: false)
      assert Enum.sort(list) == [10, 20, 20]
      # uniq? distinct count over the value set (2 distinct amounts among [10,20,20])
      assert {:ok, %{c: 2}} =
               Ash.aggregate(AttributeDoc, {:c, :count, uniq?: true, field: :amount},
                 tenant: "org3",
                 authorize?: false
               )
    end
  end

  describe "fail-closed tenancy (C12)" do
    test ":context aggregate with a BLANK tenant errors (never the base DB)" do
      # Ash core short-circuits a blank :context tenant with Ash.Error.Invalid.TenantRequired
      # BEFORE the data layer's aggregate path runs — fail-closed at the Ash layer (the base
      # DB is never touched). Value-free message: "...require a tenant to be specified".
      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.count(ContextDoc, tenant: nil, authorize?: false)

      assert Exception.message(err) =~ "require a tenant"
    end

    test ":context aggregate scoped to the tenant DB (cross-tenant count excluded)", %{
      ta: ta,
      tb: tb
    } do
      seed_ctx(ta, [1, 2])
      seed_ctx(tb, [9, 9, 9])
      assert {:ok, 2} == Ash.count(ContextDoc, tenant: ta, authorize?: false)
      assert {:ok, 3} == Ash.count(ContextDoc, tenant: tb, authorize?: false)
    end
  end

  describe "pagination count" do
    test "offset pagination count: true routes through run_aggregate_query" do
      seed_attr("org_pag", [1, 2, 3, 4, 5])

      assert {:ok, %Ash.Page.Offset{count: 5}} =
               Ash.read(AttributeDoc,
                 tenant: "org_pag",
                 authorize?: false,
                 page: [limit: 2, count: true]
               )
    end
  end
end
