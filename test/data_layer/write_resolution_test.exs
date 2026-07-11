defmodule AshArcadic.DataLayer.WriteResolutionTest do
  use ExUnit.Case, async: true
  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Query

  defmodule ContextRes do
    use Ash.Resource, domain: nil, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
    end

    attributes do
      uuid_primary_key :id
    end

    multitenancy do
      strategy :context
    end
  end

  defmodule ContextWithDatabaseRes do
    use Ash.Resource, domain: nil, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
      # Spec §6: `database` is IGNORED for :context (the tenant resolves it). A
      # static value here must NOT pre-seed query.database and defeat the read
      # fail-closed backstop.
      database("static_base")
    end

    attributes do
      uuid_primary_key(:id)
    end

    multitenancy do
      strategy :context
    end
  end

  test "resource_to_query ignores the static `database` DSL for :context (spec §6) — no pre-seed defeats the read backstop" do
    query = DL.resource_to_query(ContextWithDatabaseRes, nil)
    # `database` must NOT leak into the query for :context — otherwise read_conn
    # sees a nonblank database and reads it even when set_tenant never fired.
    assert query.database == nil

    # Consequence: a :context read with no resolved tenant fails CLOSED, never
    # silently reads the static database.
    assert {:error, :tenant_required} = DL.read_conn(query, ContextWithDatabaseRes)
  end

  test "write_database :context fails closed on a nil/blank tenant (no base fallthrough)" do
    assert {:error, :tenant_required} =
             DL.write_database(ContextRes, %Ash.Changeset{resource: ContextRes, to_tenant: nil})

    assert {:error, :tenant_required} =
             DL.write_database(ContextRes, %Ash.Changeset{resource: ContextRes, to_tenant: ""})
  end

  test "write_database :context resolves the tenant database for a present tenant" do
    assert {:ok, "t_acme"} =
             DL.write_database(ContextRes, %Ash.Changeset{resource: ContextRes, to_tenant: "acme"})
  end

  test "write_database on a non-multitenant resource returns the (possibly nil) resource database" do
    assert {:ok, nil} =
             DL.write_database(AshArcadic.Test.Basic, %Ash.Changeset{
               resource: AshArcadic.Test.Basic,
               to_tenant: nil
             })
  end

  test "read_conn :context fails closed when set_tenant never populated a database" do
    assert {:error, :tenant_required} =
             DL.read_conn(%Query{resource: ContextRes, database: nil}, ContextRes)
  end

  test "read_conn :context re-targets the connection to the resolved tenant database" do
    assert {:ok, %Arcadic.Conn{database: "t_acme"}} =
             DL.read_conn(%Query{resource: ContextRes, database: "t_acme"}, ContextRes)
  end

  test "read_conn on a non-multitenant resource uses the client's base connection" do
    assert {:ok, %Arcadic.Conn{database: "ash_arcadic_test"}} =
             DL.read_conn(
               %Query{resource: AshArcadic.Test.Basic, database: nil},
               AshArcadic.Test.Basic
             )
  end

  test "write_conn :context fails closed on a blank tenant" do
    assert {:error, :tenant_required} =
             DL.write_conn(ContextRes, %Ash.Changeset{resource: ContextRes, to_tenant: nil})
  end

  test "write_conn :context re-targets the write connection to the resolved tenant database" do
    assert {:ok, %Arcadic.Conn{database: "t_acme"}} =
             DL.write_conn(ContextRes, %Ash.Changeset{resource: ContextRes, to_tenant: "acme"})
  end

  test "write_conn on a non-multitenant resource uses the client's base connection" do
    assert {:ok, %Arcadic.Conn{database: "ash_arcadic_test"}} =
             DL.write_conn(AshArcadic.Test.Basic, %Ash.Changeset{
               resource: AshArcadic.Test.Basic,
               to_tenant: nil
             })
  end

  # query_write_conn/2 is the SOLE conn resolver for the query-scoped bulk writes
  # (update_query/destroy_query). Its :context blank-tenant fail-closed arm is a DEFENSE-IN-DEPTH
  # backstop: Ash's bulk path rejects a blank :context tenant UPSTREAM (Bulk.validate_multitenancy),
  # so the only bulk-write integration test that reaches it is Ash-shadowed and proves Ash-core, not
  # this arm. These DB-free units exercise the arm DIRECTLY — a fall-through to the base database
  # would be a silent cross-tenant write (spec §9/§12 #2).
  test "query_write_conn :context fails closed on a nil/blank tenant (no base fallthrough)" do
    assert {:error, :tenant_required} =
             DL.query_write_conn(%Query{resource: ContextRes, database: nil}, ContextRes)

    assert {:error, :tenant_required} =
             DL.query_write_conn(%Query{resource: ContextRes, database: ""}, ContextRes)
  end

  test "query_write_conn :context re-targets the write connection to the resolved tenant database" do
    assert {:ok, %Arcadic.Conn{database: "t_acme"}} =
             DL.query_write_conn(%Query{resource: ContextRes, database: "t_acme"}, ContextRes)
  end

  test "query_write_conn on a non-multitenant resource uses the client's base connection" do
    assert {:ok, %Arcadic.Conn{database: "ash_arcadic_test"}} =
             DL.query_write_conn(
               %Query{resource: AshArcadic.Test.Basic, database: nil},
               AshArcadic.Test.Basic
             )
  end

  # update_many/3 resolves its write conn via write_conn_for_tenant/2 keyed on the representative
  # changeset's NORMALIZED to_tenant (sibling parity with the single-row write_conn/2 and the bulk
  # upsert path — NOT the raw opts.tenant). Its :context blank-tenant fail-closed arm is the SAME
  # defense-in-depth backstop as query_write_conn's: Ash's bulk path rejects a blank :context tenant
  # UPSTREAM (Bulk.validate_multitenancy), so the integration path is Ash-shadowed. This DB-free unit
  # drives the callback DIRECTLY with a blank to_tenant on the changeset — a fall-through to the base
  # database would be a silent cross-tenant write. It fails closed BEFORE any Arcadic.command
  # (write_conn_for_tenant returns {:error, :tenant_required}), so no live server is needed.
  # Non-vacuity: the reason is the EXACT :tenant_required string — an incidental crash would raise, not
  # return this value-free %UpdateFailed{}.
  test "update_many :context fails closed on a nil/blank tenant, value-free (DB-free backstop)" do
    for tenant <- [nil, ""] do
      # The representative changeset carries the (blank) to_tenant — update_many scopes by it, so the
      # loop exercises BOTH the nil and the "" branch of write_database_for_tenant's :context guard.
      cs = %Ash.Changeset{
        resource: ContextRes,
        data: struct(ContextRes, %{id: "11111111-1111-1111-1111-111111111111"}),
        to_tenant: tenant,
        attributes: %{},
        atomics: [],
        filter: nil
      }

      assert {:error, %AshArcadic.Errors.UpdateFailed{} = err} =
               DL.update_many(ContextRes, [cs], %{tenant: tenant})

      assert err.reason == "multitenancy tenant required for :context write"
      # Value-free: the reason names no PK value, tenant name, or Cypher.
      refute err.reason =~ "11111111"
    end
  end
end
