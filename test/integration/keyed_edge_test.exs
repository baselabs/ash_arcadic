defmodule AshArcadic.Integration.KeyedEdgeTest do
  use AshArcadic.Test.IntegrationCase

  defmodule Node do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client AshArcadic.Test.IntegrationClient
      label :ProjectionNode

      edge :link do
        label :ProjectionEdge
        direction :both
        destination AshArcadic.Integration.KeyedEdgeTest.Node
        properties [:edge_key, :kind]
        identity [:edge_key]
      end
    end

    multitenancy do
      strategy :attribute
      attribute :tenant
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :tenant, :string, public?: true
    end

    actions do
      default_accept [:id]
      defaults [:read, :create]

      update :link do
        require_atomic? false
        argument :to, :string, allow_nil?: false
        argument :edge_key, :string, allow_nil?: false
        argument :kind, :string
        change {AshArcadic.Changes.CreateEdge, edge: :link, to: :to}
      end

      update :unlink do
        require_atomic? false
        argument :to, :string, allow_nil?: false
        argument :edge_key, :string, allow_nil?: false
        change {AshArcadic.Changes.DestroyEdge, edge: :link, to: :to}
      end

      update :relocate do
        require_atomic? false
        argument :to, :string
        argument :edge_key, :string, allow_nil?: false
        argument :kind, :string
        change {AshArcadic.Changes.CreateEdge, edge: :link, to: :to, replace?: true}
      end
    end
  end

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:ProjectionNode) DETACH DELETE n") end)
    :ok
  end

  test "parallel keys replay independently, remove by key and relocate across both endpoints", %{
    admin: admin
  } do
    a = Ash.create!(Node, %{id: "a"}, tenant: "one")
    c = Ash.create!(Node, %{id: "c"}, tenant: "one")
    for id <- ["b", "d"], do: Ash.create!(Node, %{id: id}, tenant: "one")
    Ash.create!(Node, %{id: "foreign"}, tenant: "two")

    for _ <- 1..3, do: assert({:ok, _} = link(a, :link, "b", "A"))
    assert {:ok, _} = link(a, :link, "b", "B")
    assert edges(admin) == [{"a", "b", "A", "relation"}, {"a", "b", "B", "relation"}]

    assert {:ok, _} = Ash.update(a, %{to: "b", edge_key: "A"}, action: :unlink, tenant: "one")
    assert edges(admin) == [{"a", "b", "B", "relation"}]

    assert {:ok, _} = link(a, :link, "b", "A")
    assert {:error, _} = link(c, :relocate, nil, "A")
    assert {:error, _} = link(c, :relocate, "foreign", "A")
    assert edges(admin) == [{"a", "b", "A", "relation"}, {"a", "b", "B", "relation"}]

    for _ <- 1..2, do: assert({:ok, _} = link(c, :relocate, "d", "A"))
    assert edges(admin) == [{"a", "b", "B", "relation"}, {"c", "d", "A", "relation"}]
  end

  test "keyed unlink targets the outgoing placement and refuses duplicate outgoing matches", %{
    admin: admin
  } do
    a = Ash.create!(Node, %{id: "left"}, tenant: "one")
    b = Ash.create!(Node, %{id: "right"}, tenant: "one")

    assert {:ok, _} = link(a, :link, "right", "C")
    assert {:ok, _} = link(b, :link, "left", "C")
    assert {:ok, _} = Ash.update(a, %{to: "right", edge_key: "C"}, action: :unlink, tenant: "one")
    assert placements(admin, "C") == [{"right", "left", "C", "relation"}]

    for _ <- 1..2 do
      Arcadic.command!(admin, """
      MATCH (a:ProjectionNode {id:'left'}), (b:ProjectionNode {id:'right'})
      CREATE (a)-[:ProjectionEdge {edge_key:'C', tenant:'one'}]->(b)
      """)
    end

    before = placements(admin, "C")
    assert length(before) == 3

    assert {:error, _} =
             Ash.update(a, %{to: "right", edge_key: "C"}, action: :unlink, tenant: "one")

    assert placements(admin, "C") == before
  end

  defp placements(admin, key), do: Enum.filter(edges(admin), &(elem(&1, 2) == key))

  defp link(source, action, destination, key) do
    Ash.update(source, %{to: destination, edge_key: key, kind: "relation"},
      action: action,
      tenant: "one"
    )
  end

  defp edges(admin) do
    admin
    |> Arcadic.query!("""
    MATCH (a:ProjectionNode)-[e:ProjectionEdge]->(b:ProjectionNode)
    RETURN a.id AS src, b.id AS dst, e.edge_key AS key, e.kind AS kind
    """)
    |> Enum.map(&{&1["src"], &1["dst"], &1["key"], &1["kind"]})
    |> Enum.sort()
  end
end
