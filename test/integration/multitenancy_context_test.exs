defmodule AshArcadic.Integration.MultitenancyContextTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Multitenancy
  alias AshArcadic.Test.ContextDoc

  # :context = database-per-tenant. Provision the two tenant databases (distinct
  # from the IntegrationCase base DB, which set_tenant/3 overrides) and drop them.
  setup %{admin: admin} do
    t1 = "tenant1_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    t2 = "tenant2_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    for tenant <- [t1, t2] do
      Arcadic.Server.create_database!(admin, Multitenancy.database_name(ContextDoc, tenant))
    end

    on_exit(fn ->
      for tenant <- [t1, t2],
          do: Arcadic.Server.drop_database(admin, Multitenancy.database_name(ContextDoc, tenant))
    end)

    {:ok, t1: t1, t2: t2}
  end

  test "a record created in tenant 1 is invisible to tenant 2 (physical database isolation)", %{
    t1: t1,
    t2: t2
  } do
    {:ok, _} =
      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: "x", name: "A"}, tenant: t1)
      |> Ash.create()

    {:ok, in_t1} = ContextDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: t1)
    {:ok, in_t2} = ContextDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: t2)

    assert Enum.map(in_t1, & &1.name) == ["A"]
    assert in_t2 == []
  end

  test "a :context create with no tenant fails closed (no silent base-database write)" do
    assert_raise Ash.Error.Invalid, fn ->
      ContextDoc |> Ash.Changeset.for_create(:create, %{id: "y", name: "B"}) |> Ash.create!()
    end
  end

  test "mutations are physically isolated: a destroy in tenant 1 leaves tenant 2's own record intact",
       %{t1: t1, t2: t2} do
    # Both tenants use id "z" — legal because they live in physically separate
    # databases (set_tenant/3 re-targets each write/read). A shared-DB or leaking
    # implementation would collide or cross-delete; independent DBs do neither.
    {:ok, z1} =
      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: "z", name: "T1"}, tenant: t1)
      |> Ash.create()

    {:ok, _} =
      ContextDoc
      |> Ash.Changeset.for_create(:create, %{id: "z", name: "T2"}, tenant: t2)
      |> Ash.create()

    :ok = z1 |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: t1) |> Ash.destroy()

    {:ok, in_t1} = ContextDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: t1)
    {:ok, in_t2} = ContextDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: t2)

    assert in_t1 == []
    # t2's row physically survives in its own DB — the t1 destroy never reached it.
    assert Enum.map(in_t2, & &1.name) == ["T2"]
  end
end
