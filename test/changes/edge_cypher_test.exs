defmodule AshArcadic.Changes.EdgeCypherTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Changes.EdgeCypher

  test "tenant_where/1 scopes BOTH endpoints for {src_attr, dest_attr, value}" do
    assert {clause, %{"tenant" => "org1"}} = EdgeCypher.tenant_where({:tenant, :tenant, "org1"})
    assert clause == " AND a.tenant = $tenant AND b.tenant = $tenant"
  end

  test "tenant_where/1 omits the dest clause when dest_attr is nil (non-multitenant dest)" do
    assert {clause, %{"tenant" => "org1"}} = EdgeCypher.tenant_where({:tenant, nil, "org1"})
    assert clause == " AND a.tenant = $tenant"
  end

  test "tenant_where/1 is empty for nil (no :attribute source)" do
    assert EdgeCypher.tenant_where(nil) == {"", %{}}
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
end
