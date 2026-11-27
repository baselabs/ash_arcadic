defmodule AshArcadic.Integration.StoredTypesTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query

  alias AshArcadic.DataLayer
  alias AshArcadic.Query.Write
  alias AshArcadic.Test.IntegrationClient
  alias AshArcadic.Test.StoredType
  alias AshArcadic.Test.Visibility

  defmodule Node do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(IntegrationClient)
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :kind, :atom, public?: true
      attribute :access, :atom, constraints: [one_of: [:public, :internal]], public?: true
      attribute :visibility, Visibility, public?: true
      attribute :badge, StoredType, public?: true
      attribute :payload, :term, public?: true
    end

    actions do
      default_accept [:id, :kind, :access, :visibility, :badge, :payload]
      defaults [:read, :create, :update]
    end
  end

  test "create results and reads load the declared Ash types" do
    expected = %{kind: :document, access: :public, visibility: :internal, badge: "VIP"}
    attrs = %{expected | badge: "vip"}

    assert {:ok, created} = Ash.create(Node, Map.put(attrs, :id, "node"))
    assert Map.take(created, Map.keys(expected)) == expected

    assert {:ok, read} = Ash.get(Node, "node")
    assert Map.take(read, Map.keys(expected)) == expected
  end

  test "Ash writes and filters native term values" do
    assert {:ok, %{payload: "hello"} = node} = Ash.create(Node, %{id: "term", payload: "hello"})
    assert %{payload: "hello"} = Ash.get!(Node, "term")

    payload = {:updated, "hello"}
    assert {:ok, %{payload: ^payload}} = Ash.update(node, %{payload: payload})
    query = Ash.Query.filter(Node, payload == ^payload)
    assert [%{id: "term", payload: ^payload}] = Ash.read!(query)
  end

  test "bulk writes and upserts use the same term representation" do
    entries = [
      Ash.Changeset.for_create(Node, :create, %{id: "bulk-term", payload: "first"})
    ]

    assert {:ok, [%{payload: "first"}]} =
             DataLayer.bulk_create(Node, entries, %{return_records?: true})

    upsert = Ash.Changeset.for_create(Node, :create, %{id: "bulk-term", payload: "second"})
    assert {:ok, %{payload: "second"}} = DataLayer.upsert(Node, upsert, [:id])
    assert %{payload: "second"} = Ash.get!(Node, "bulk-term")
  end

  test "literal atomic assignments bind the native term dump" do
    assert {:ok, ["n.payload = $param1"], %{"param1" => encoded}} =
             Write.atomic_fragments(Node, [payload: "hello"], %{})

    assert Base.decode64!(encoded) == :erlang.term_to_binary("hello")
  end
end
