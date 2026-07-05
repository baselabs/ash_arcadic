defmodule AshArcadic.Changes.DestroyEdgeTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Changes.DestroyEdge
  alias AshArcadic.Test.EdgeAttrPerson

  defp edge(overrides \\ []) do
    struct(
      %AshArcadic.Edge{
        name: :friends,
        label: :KNOWS,
        direction: :outgoing,
        destination: EdgeAttrPerson
      },
      overrides
    )
  end

  test "build_destroy/5 matches the directed edge, scopes both endpoints, DELETEs r" do
    {cypher, params} =
      DestroyEdge.build_destroy(
        EdgeAttrPerson,
        edge(),
        %{"id" => "p1"},
        "p2",
        {:tenant, :tenant, "org1"}
      )

    assert cypher =~ "MATCH (a:EAPerson)-[r:KNOWS]->(b:EAPerson)"

    assert cypher =~
             "WHERE a.id = $src_id AND b.id = $dst AND a.tenant = $tenant AND b.tenant = $tenant"

    assert cypher =~ "DELETE r RETURN r"
    assert params["src_id"] == "p1"
    assert params["dst"] == "p2"
    assert params["tenant"] == "org1"
  end

  test "incoming direction flips the match pattern" do
    {cypher, _} =
      DestroyEdge.build_destroy(
        EdgeAttrPerson,
        edge(direction: :incoming),
        %{"id" => "p1"},
        "p2",
        nil
      )

    assert cypher =~ "MATCH (a:EAPerson)<-[r:KNOWS]-(b:EAPerson)"
  end
end
