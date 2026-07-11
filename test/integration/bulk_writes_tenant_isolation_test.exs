defmodule AshArcadic.Integration.BulkWritesTenantIsolationTest do
  @moduledoc """
  Security (spec §9/§13): a fabricated cross-tenant attacker cannot bulk-update or bulk-destroy
  another tenant's rows. Each proof is non-vacuous — the victim's rows survive unchanged, and the
  mutation step documents the no-scope reddening (dropping `where_and_params/1`'s WHERE in
  `lib/ash_arcadic/query.ex` reddens the org2-survival assertions in both :attribute tests).
  """
  use AshArcadic.Test.IntegrationCase

  require Ash.Expr
  require Ash.Query
  alias AshArcadic.Test.CalcTenantPerson, as: P

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CalcTenantPerson) DETACH DELETE n") end)

    # Seed the VICTIM tenant (org2) FIRST and independently — never reuse a loaded victim
    # as the attacker (a loaded record's __metadata__.tenant would scope legitimately).
    for {id, a} <- [{"v1", 10}, {"v2", 20}] do
      P
      |> Ash.Changeset.for_create(:create, %{id: id, org_id: "org2", a: a, b: 0})
      |> Ash.create!(tenant: "org2")
    end

    for {id, a} <- [{"a1", 1}, {"a2", 2}] do
      P
      |> Ash.Changeset.for_create(:create, %{id: id, org_id: "org1", a: a, b: 0})
      |> Ash.create!(tenant: "org1")
    end

    :ok
  end

  # Invocation form (probed on ash 3.29.3): the tenant must ride BOTH the query
  # (`for_read(:read, %{}, tenant: ...)` — a pre-validated query skips bulk's internal
  # tenant-attaching for_read) AND the bulk opts (`Bulk.validate_multitenancy` checks
  # `opts[:tenant]`). Either alone yields TenantRequired.
  test ":attribute bulk update under org1 never touches org2 rows" do
    P
    |> Ash.Query.for_read(:read, %{}, tenant: "org1")
    |> Ash.bulk_update!(:update, %{a: Ash.Expr.expr(a + 1000)},
      tenant: "org1",
      strategy: :atomic,
      return_records?: false
    )

    org1 = P |> Ash.read!(tenant: "org1") |> Enum.map(& &1.a) |> Enum.sort()
    assert org1 == [1001, 1002]

    # Non-vacuous: dropping the tenant WHERE mutates org2 too ([1010, 1020]) — proven RED.
    org2 = P |> Ash.read!(tenant: "org2") |> Enum.map(& &1.a) |> Enum.sort()
    assert org2 == [10, 20]
  end

  test ":attribute bulk destroy under org1 never deletes org2 rows" do
    P
    |> Ash.Query.for_read(:read, %{}, tenant: "org1")
    |> Ash.bulk_destroy!(:destroy, %{}, tenant: "org1", strategy: :atomic)

    assert P |> Ash.read!(tenant: "org1") == []

    # Non-vacuous: dropping the tenant WHERE deletes org2's rows too — proven RED.
    org2 = P |> Ash.read!(tenant: "org2") |> Enum.map(& &1.id) |> Enum.sort()
    assert org2 == ["v1", "v2"]
  end

  describe ":context isolation" do
    alias AshArcadic.Multitenancy
    alias AshArcadic.Test.ContextDoc

    setup %{admin: admin} do
      t1 = "octx1_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
      t2 = "octx2_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

      for t <- [t1, t2] do
        Arcadic.Server.create_database!(admin, Multitenancy.database_name(ContextDoc, t))
      end

      on_exit(fn ->
        for t <- [t1, t2],
            do: Arcadic.Server.drop_database(admin, Multitenancy.database_name(ContextDoc, t))
      end)

      {:ok, t1: t1, t2: t2}
    end

    test ":context bulk update targets only the tenant's database", %{t1: t1, t2: t2} do
      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: "d1", name: "A", amount: 1})
      |> Ash.create!(tenant: t1)

      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: "d1", name: "B", amount: 9})
      |> Ash.create!(tenant: t2)

      ContextDoc
      |> Ash.Query.for_read(:read, %{}, tenant: t1)
      |> Ash.bulk_update!(:update, %{name: "Renamed"}, tenant: t1, strategy: :atomic)

      assert Ash.get!(ContextDoc, "d1", tenant: t1).name == "Renamed"
      # Physical isolation: t2's same-PK row is untouched in its own database.
      assert Ash.get!(ContextDoc, "d1", tenant: t2).name == "B"
    end

    test ":context bulk destroy targets only the tenant's database", %{t1: t1, t2: t2} do
      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: "d1", name: "A", amount: 1})
      |> Ash.create!(tenant: t1)

      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: "d1", name: "B", amount: 9})
      |> Ash.create!(tenant: t2)

      ContextDoc
      |> Ash.Query.for_read(:read, %{}, tenant: t1)
      |> Ash.bulk_destroy!(:destroy, %{}, tenant: t1, strategy: :atomic)

      assert Ash.read!(ContextDoc, tenant: t1) == []
      # Physical isolation: the same PK "d1" in t2's SEPARATE database survives.
      assert Ash.get!(ContextDoc, "d1", tenant: t2).name == "B"
    end

    test ":context blank tenant fails closed (no statement runs)" do
      # return_errors?: true so the bang raises the REAL class (Ash.Error.Invalid wrapping
      # TenantRequired, from Bulk.validate_multitenancy — before any statement); without it
      # bulk_update! raises a diagnostic-free Ash.Error.Unknown.
      assert_raise Ash.Error.Invalid, fn ->
        ContextDoc
        |> Ash.Query.for_read(:read)
        |> Ash.bulk_update!(:update, %{name: "X"}, strategy: :atomic, return_errors?: true)
      end
    end
  end
end
