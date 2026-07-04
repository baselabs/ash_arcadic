defmodule AshArcadic.IdentifierTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Identifier

  test "returns the identifier string for a valid atom or binary" do
    assert Identifier.validate!(:Person) == "Person"
    assert Identifier.validate!("Node") == "Node"
  end

  test "raises value-free on an invalid identifier (never echoes the string)" do
    err = assert_raise ArgumentError, fn -> Identifier.validate!("1bad; DROP") end
    refute err.message =~ "1bad"
    refute err.message =~ "DROP"
  end

  test "raises value-free on a leading-underscore identifier (arcadic requires letter-first)" do
    assert_raise ArgumentError, fn -> Identifier.validate!("_x") end
  end
end
