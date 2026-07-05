defmodule AshArcadic.Integration.EdgeContextTest do
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Multitenancy
  alias AshArcadic.Test.EdgeContextPerson

  # :context = database-per-tenant. The edge write carries NO discriminator stamp and
  # NO endpoint tenant clause (tenant_spec/3 → nil); physical DB isolation is what makes
  # a cross-tenant edge structurally impossible. Provision the tenant DB and drop it.
  setup %{admin: admin} do
    t = "ectx_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    db = Multitenancy.database_name(EdgeContextPerson, t)
    Arcadic.Server.create_database!(admin, db)
    on_exit(fn -> Arcadic.Server.drop_database(admin, db) end)
    {:ok, t: t, tconn: Arcadic.with_database(admin, db)}
  end

  test ":context edge write lands in the tenant's physical database (intra-tenant-DB only)", %{
    t: t,
    tconn: tconn
  } do
    {:ok, a} = create_person("a", t)
    {:ok, _} = create_person("b", t)

    {:ok, _} = befriend(a, ["b"], t)

    # The edge is readable in the TENANT database — the write ran via write_conn against
    # the per-tenant DB, not the base integration DB. A wrong-DB write would show 0 here.
    {:ok, [%{"c" => c}]} =
      Arcadic.query(
        tconn,
        "MATCH (:ECPerson {id:'a'})-[e:KNOWS]->(:ECPerson {id:'b'}) RETURN count(e) AS c",
        %{}
      )

    assert c == 1

    # And the edge carries NO tenant discriminator property — :context relies on physical
    # isolation, not the :attribute stamp. count of stamped edges must be 0.
    {:ok, [%{"c" => stamped}]} =
      Arcadic.query(
        tconn,
        "MATCH (:ECPerson {id:'a'})-[e:KNOWS]->(:ECPerson {id:'b'}) WHERE e.tenant IS NOT NULL RETURN count(e) AS c",
        %{}
      )

    assert stamped == 0
  end

  defp create_person(id, tenant) do
    EdgeContextPerson
    |> Ash.Changeset.for_create(:create, %{id: id, name: id}, tenant: tenant)
    |> Ash.create()
  end

  defp befriend(actor, to, tenant) do
    actor
    |> Ash.Changeset.for_update(:befriend, %{to: to}, tenant: tenant)
    |> Ash.update()
  end
end
