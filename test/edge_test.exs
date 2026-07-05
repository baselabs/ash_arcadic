defmodule AshArcadic.EdgeTest do
  use ExUnit.Case, async: true

  test "defaults: direction :outgoing, properties [], multiple? false" do
    edge = %AshArcadic.Edge{name: :author, label: :AUTHORED, destination: SomeMod}
    assert edge.direction == :outgoing
    assert edge.properties == []
    assert edge.multiple? == false
  end

  test "carries name/label/direction/destination/properties/multiple?" do
    edge = %AshArcadic.Edge{
      name: :friends,
      label: :KNOWS,
      direction: :both,
      destination: SomeMod,
      properties: [:since],
      multiple?: true
    }

    assert {edge.name, edge.label, edge.direction, edge.multiple?} ==
             {:friends, :KNOWS, :both, true}
  end
end
