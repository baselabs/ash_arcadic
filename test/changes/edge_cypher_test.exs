defmodule AshArcadic.Changes.EdgeCypherTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Changes.EdgeCypher
  alias AshArcadic.Test.EdgeAttrPerson

  test "tenant_where/1 scopes BOTH endpoints with per-endpoint params" do
    scope = %{src: {:tenant, "org1"}, dest: {:tenant, "org1"}}

    assert {clause, params} = EdgeCypher.tenant_where(scope)
    assert clause == " AND a.tenant = $tenant AND b.tenant = $tenant_dest"
    assert params == %{"tenant" => "org1", "tenant_dest" => "org1"}
  end

  test "tenant_where/1 scopes source-only (non-multitenant dest takes no dest clause)" do
    assert {clause, params} = EdgeCypher.tenant_where(%{src: {:tenant, "org1"}})
    assert clause == " AND a.tenant = $tenant"
    assert params == %{"tenant" => "org1"}
  end

  test "tenant_where/1 scopes DESTINATION-only (non-multitenant source, :attribute dest)" do
    # The 2026-10-16 fix: a destination-only multitenancy previously rendered NO clause
    # here, letting the MATCH bind the victim tenant's vertex by bare PK.
    assert {clause, params} = EdgeCypher.tenant_where(%{dest: {:tenant, "org1"}})
    assert clause == " AND b.tenant = $tenant_dest"
    assert params == %{"tenant_dest" => "org1"}
  end

  test "tenant_where/1 is empty for nil (no :attribute endpoint)" do
    assert EdgeCypher.tenant_where(nil) == {"", %{}}
  end

  test "tenant_spec/3 fails closed :tenant_required on a blank tenant for an :attribute endpoint" do
    changeset = %Ash.Changeset{resource: EdgeAttrPerson, to_tenant: nil}
    edge = %AshArcadic.Edge{name: :friends, destination: EdgeAttrPerson}

    assert {:error, :tenant_required} = EdgeCypher.tenant_spec(EdgeAttrPerson, edge, changeset)

    assert {:error, :tenant_required} =
             EdgeCypher.tenant_spec(EdgeAttrPerson, edge, %{changeset | to_tenant: ""})
  end

  test "tenant_spec/3 normalizes a struct tenant via Ash.ToTenant before binding (dest-only scope)" do
    # Mirror of update_many/vector tenant predicates: the WHERE must bind the NORMALIZED
    # tenant, not the raw term — a raw %OrgRef{} would never match a stored string row.
    changeset = %Ash.Changeset{
      resource: AshArcadic.Test.Unlabelled,
      to_tenant: %AshArcadic.Test.OrgRef{id: "acme"}
    }

    edge = %AshArcadic.Edge{name: :x, destination: AshArcadic.Test.CustomTenantDoc}

    # Global source (no src scope) + :attribute destination → DEST-only scoping, the
    # 2026-10-16 fix's shape.
    assert {:ok, %{dest: {attr, bound}}} =
             EdgeCypher.tenant_spec(AshArcadic.Test.Unlabelled, edge, changeset)

    assert attr == :org_id
    assert bound == "acme"
  end

  test "source_where/1 binds each PK field as $src_<field>" do
    assert {clause, params} = EdgeCypher.source_where(%{"id" => "p1"})
    assert clause == "a.id = $src_id"
    assert params == %{"src_id" => "p1"}
  end

  test "encode_gate/1 passes a fully JSON-encodable param map" do
    assert EdgeCypher.encode_gate(%{"props" => %{"since" => "2020"}, "dst" => "p2"}) == :ok
  end

  test "encode_gate/1 fails closed value-free on a nested raw binary, naming only the key" do
    poisoned = %{"props" => %{"blob" => <<0xFF, 0xFE>>}, "dst" => "p2"}
    assert {:error, "props"} = EdgeCypher.encode_gate(poisoned)
  end

  test "serialize_destination_ids/2 raises the value-free single-attribute-PK error for a composite dest PK" do
    # A composite destination PK must surface the designed value-free ArgumentError
    # (matching destination_pk!), NOT a cryptic MatchError from a `[single] = pk`
    # destructure that fires first at the change's write site.
    err =
      assert_raise ArgumentError, fn ->
        EdgeCypher.serialize_destination_ids(AshArcadic.Test.UpsertComposite, ["r1"])
      end

    assert err.message =~ "single-attribute primary key"
  end
end
