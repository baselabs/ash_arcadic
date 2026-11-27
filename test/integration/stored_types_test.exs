defmodule AshArcadic.Integration.StoredTypesTest do
  use AshArcadic.Test.IntegrationCase

  defmodule Node do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.IntegrationClient)
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :kind, :atom, public?: true
      attribute :access, :atom, constraints: [one_of: [:public, :internal]], public?: true
      attribute :visibility, AshArcadic.Test.Visibility, public?: true
      attribute :badge, AshArcadic.Test.StoredType, public?: true
    end

    actions do
      default_accept [:id, :kind, :access, :visibility, :badge]
      defaults [:read, :create]
    end
  end

  test "create results and reads load the declared Ash types" do
    expected = %{kind: :document, access: :public, visibility: :internal, badge: "VIP"}
    attrs = %{expected | badge: "stored:vip"}

    assert {:ok, created} = Ash.create(Node, Map.put(attrs, :id, "node"))
    assert Map.take(created, Map.keys(expected)) == expected

    assert {:ok, read} = Ash.get(Node, "node")
    assert Map.take(read, Map.keys(expected)) == expected
  end
end
