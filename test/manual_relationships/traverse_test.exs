defmodule AshArcadic.ManualRelationships.TraverseTest do
  use ExUnit.Case, async: true

  alias AshArcadic.ManualRelationships.Traverse

  describe "validate_opts!/1" do
    test "defaults direction :outgoing, min_depth 1; returns {edge, dir, min, max}" do
      assert {:PARENT_OF, :outgoing, 1, 3} =
               Traverse.validate_opts!(edge_label: :PARENT_OF, max_depth: 3)
    end

    test "honors explicit direction + min_depth" do
      assert {:KNOWS, :incoming, 2, 4} =
               Traverse.validate_opts!(
                 edge_label: :KNOWS,
                 direction: :incoming,
                 min_depth: 2,
                 max_depth: 4
               )
    end

    test "raises value-free when :edge_label missing" do
      assert_raise ArgumentError, ~r/requires :edge_label/, fn ->
        Traverse.validate_opts!(max_depth: 2)
      end
    end

    test "raises on a bad direction" do
      assert_raise ArgumentError, ~r/:direction must be/, fn ->
        Traverse.validate_opts!(edge_label: :E, direction: :sideways, max_depth: 2)
      end
    end

    test "raises when :max_depth missing or < 1 (unbounded * forbidden)" do
      assert_raise ArgumentError, ~r/max_depth must be an integer >= 1/, fn ->
        Traverse.validate_opts!(edge_label: :E)
      end

      assert_raise ArgumentError, ~r/max_depth/, fn ->
        Traverse.validate_opts!(edge_label: :E, max_depth: 0)
      end
    end

    test "raises when min_depth < 1 or min_depth > max_depth" do
      assert_raise ArgumentError, ~r/min_depth/, fn ->
        Traverse.validate_opts!(edge_label: :E, min_depth: 0, max_depth: 2)
      end

      assert_raise ArgumentError, ~r/min_depth/, fn ->
        Traverse.validate_opts!(edge_label: :E, min_depth: 3, max_depth: 2)
      end
    end

    test "TRIPWIRE: raises value-free on a non-identifier edge_label (never echoes the value)" do
      err =
        assert_raise ArgumentError, fn ->
          Traverse.validate_opts!(edge_label: :"bad-label", max_depth: 2)
        end

      refute err.message =~ "bad-label"
    end
  end
end
