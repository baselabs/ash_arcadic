defmodule AshArcadic.Integration.ClientRoutingTest do
  use AshArcadic.Test.IntegrationCase

  defmodule Client do
    @moduledoc false
    @behaviour AshArcadic.Client

    @impl true
    def conn(%{context: %{route: :secondary}}) do
      conn = AshArcadic.Test.IntegrationClient.conn()
      Arcadic.with_database(conn, conn.database <> "_secondary")
    end

    def conn(_context), do: AshArcadic.Test.IntegrationClient.conn()
  end

  defmodule Node do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      label :RoutedNode
      client AshArcadic.Integration.ClientRoutingTest.Client
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      default_accept [:id]
      defaults [:create, :read]
    end
  end

  test "same-server routes to different databases stay isolated inside one Ash transaction", %{
    admin: admin,
    database: database
  } do
    secondary = database <> "_secondary"
    :ok = Arcadic.Server.create_database!(admin, secondary)
    on_exit(fn -> Arcadic.Server.drop_database(admin, secondary) end)

    Arcadic.command!(
      Arcadic.with_database(admin, secondary),
      "CREATE (n:RoutedNode {id:'second'})"
    )

    assert {:ok, :done} =
             Ash.transact(Node, fn ->
               assert {:ok, _} = Ash.create(Node, %{id: "first"})
               assert {:ok, [%{id: "first"}]} = Ash.read(Node)
               assert {:ok, [%{id: "second"}]} = Ash.read(Node, context: %{route: :secondary})

               assert {:error, error} =
                        Ash.create(Node, %{id: "escaped"}, context: %{route: :secondary})

               assert Exception.message(error) =~ "transaction spans multiple databases"
               {:ok, :done}
             end)

    assert {:ok, [%{id: "first"}]} = Ash.read(Node)
    assert {:ok, [%{id: "second"}]} = Ash.read(Node, context: %{route: :secondary})
  end
end
