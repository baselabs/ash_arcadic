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

  test "fails closed on degenerate atoms (nil/booleans must not become a literal identifier)" do
    assert_raise ArgumentError, fn -> Identifier.validate!(nil) end
    assert_raise ArgumentError, fn -> Identifier.validate!(true) end
    assert_raise ArgumentError, fn -> Identifier.validate!(false) end
  end

  test "raises value-free on an invalid atom (the invalid-atom path)" do
    err = assert_raise ArgumentError, fn -> Identifier.validate!(:"1bad") end
    refute err.message =~ "1bad"
  end

  test "raises a value-free ArgumentError (not FunctionClauseError) on non-atom/binary input" do
    err = assert_raise ArgumentError, fn -> Identifier.validate!(123) end
    refute err.message =~ "123"
  end
end
