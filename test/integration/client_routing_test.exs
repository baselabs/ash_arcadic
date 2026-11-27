defmodule AshArcadic.Integration.ClientRoutingTest do
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Test.IntegrationClient

  defmodule Client do
    @moduledoc false
    @behaviour AshArcadic.Client

    @impl true
    def conn(%{context: %{route: :secondary}}) do
      conn = IntegrationClient.conn()
      Arcadic.with_database(conn, conn.database <> "_secondary")
    end

    def conn(_context), do: IntegrationClient.conn()
  end

  defmodule Node do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    alias AshArcadic.Integration.ClientRoutingTest.Client
    alias AshArcadic.ManualRelationships.Traverse

    arcade do
      label :RoutedNode
      client Client
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    relationships do
      has_many :descendants, __MODULE__ do
        destination_attribute :id
        manual {Traverse, edge_label: :ROUTE_LINK, max_depth: 2}
        public? true
      end
    end

    aggregates do
      list :descendant_names, :descendants, :name, public?: true
    end

    actions do
      default_accept [:id, :name]
      defaults [:create, :read]
    end
  end

  setup_all %{admin: admin} do
    Arcadic.command!(admin, "CREATE VERTEX TYPE RoutedNode", %{}, language: "sql")
    :ok
  end

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:RoutedNode) DETACH DELETE n") end)
    :ok
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

               :done
             end)

    assert {:error, error} =
             Ash.transact(Node, fn ->
               assert {:ok, _} = Ash.create(Node, %{id: "rolled_back"})
               Ash.create(Node, %{id: "escaped"}, context: %{route: :secondary})
             end)

    assert Exception.message(error) =~ "transaction spans multiple databases"
    assert {:ok, [%{id: "first"}]} = Ash.read(Node)
    assert {:ok, [%{id: "second"}]} = Ash.read(Node, context: %{route: :secondary})
  end

  test "traversal and inline aggregates keep the source route on nested reads", %{
    admin: admin,
    database: database
  } do
    secondary = database <> "_secondary"
    :ok = Arcadic.Server.create_database!(admin, secondary)
    on_exit(fn -> Arcadic.Server.drop_database(admin, secondary) end)
    other = Arcadic.with_database(admin, secondary)

    seed_graph(admin, "primary", ["p"])
    seed_graph(other, "secondary", ["p", "q"])

    assert %{descendants: descendants} =
             Ash.get!(Node, "root", context: %{route: :secondary}, load: [:descendants])

    assert Enum.sort(Enum.map(descendants, & &1.name)) == ["secondary-p", "secondary-q"]

    assert %{descendant_names: names} =
             Ash.get!(Node, "root", context: %{route: :secondary}, load: [:descendant_names])

    assert Enum.sort(names) == ["secondary-p", "secondary-q"]
  end

  defp seed_graph(conn, route, destinations) do
    Arcadic.command!(conn, "MERGE (n:RoutedNode {id:'root'})")

    for id <- destinations do
      Arcadic.command!(
        conn,
        "MATCH (a:RoutedNode {id:'root'}) MERGE (b:RoutedNode {id:$id}) " <>
          "SET b.name = $name MERGE (a)-[:ROUTE_LINK]->(b)",
        %{"id" => id, "name" => route <> "-" <> id}
      )
    end
  end
end
