defmodule AshArcadic.DataLayer.ClientRoutingTest do
  use ExUnit.Case, async: true

  alias AshArcadic.DataLayer

  defmodule Client do
    @moduledoc false
    @behaviour AshArcadic.Client

    @impl true
    def conn(%{tenant: tenant, context: %{region: region} = context}) do
      refute Map.has_key?(context, :private)
      refute Map.has_key?(context, :actor)
      Arcadic.connect("https://#{region}.example", tenant, auth: {"test", "unused"})
    end
  end

  defmodule Node do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client AshArcadic.DataLayer.ClientRoutingTest.Client
    end

    multitenancy do
      strategy :attribute
      attribute :tenant
    end

    attributes do
      uuid_primary_key :id
      attribute :tenant, :string, allow_nil?: false
    end
  end

  test "a dynamically routed client without a transport declaration does not advertise locks" do
    refute DataLayer.can?(Node, {:lock, :for_update})
  end

  test "writes and reads resolve using tenant and actor-free action context" do
    context = %{region: "eu", actor: %{id: "public actor"}, private: %{actor: %{id: "actor"}}}
    changeset = %Ash.Changeset{resource: Node, to_tenant: "tenant", context: context}

    assert {:ok, %Arcadic.Conn{base_url: "https://eu.example", database: "tenant"}} =
             DataLayer.write_conn(Node, changeset)

    query = DataLayer.resource_to_query(Node, nil)

    assert {:ok, query} =
             DataLayer.set_context(Node, query, put_in(context, [:private, :tenant], "tenant"))

    assert {:ok, %Arcadic.Conn{base_url: "https://eu.example", database: "tenant"}} =
             DataLayer.read_conn(query, Node)
  end
end
