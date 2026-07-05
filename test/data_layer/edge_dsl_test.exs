defmodule AshArcadic.DataLayer.EdgeDslTest do
  use ExUnit.Case, async: true
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Test.EdgeAttrPerson

  test "Info.edges/1 returns the declared %AshArcadic.Edge{}" do
    assert [%AshArcadic.Edge{} = edge] = Info.edges(EdgeAttrPerson)
    assert edge.name == :friends
    assert edge.label == :KNOWS
    assert edge.direction == :outgoing
    assert edge.destination == EdgeAttrPerson
    assert edge.properties == [:since]
    assert edge.multiple? == false
  end

  test "Info.edges/1 is [] for a resource with no edges" do
    assert Info.edges(AshArcadic.Test.Basic) == []
  end
end
