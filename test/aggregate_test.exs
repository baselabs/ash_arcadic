defmodule AshArcadic.AggregateTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Aggregate

  # {type, constraints} specs by attribute name for the guard/decode.
  @types %{
    amount: {Ash.Type.Integer, []},
    price: {Ash.Type.Decimal, []},
    secret: {Ash.Type.Binary, []},
    name: {Ash.Type.String, []}
  }

  defp agg(kind, opts \\ []) do
    struct(
      Ash.Query.Aggregate,
      Keyword.merge([name: :agg, kind: kind, field: nil, uniq?: false], opts)
    )
  end

  describe "guard_field/2 — value-free correctness + leak guard (§6.4)" do
    test "count is always allowed (any field / no field / uniq?)" do
      assert Aggregate.guard_field(agg(:count), @types) == :ok
      assert Aggregate.guard_field(agg(:count, field: :secret), @types) == :ok
      assert Aggregate.guard_field(agg(:count, field: :amount, uniq?: true), @types) == :ok
    end

    test "sum/avg require numeric storage; reject decimal/binary/string" do
      assert Aggregate.guard_field(agg(:sum, field: :amount), @types) == :ok

      assert {:error, {:unaggregatable, :price, :sum}} =
               Aggregate.guard_field(agg(:sum, field: :price), @types)

      assert {:error, {:unaggregatable, :secret, :avg}} =
               Aggregate.guard_field(agg(:avg, field: :secret), @types)
    end

    test "min/max/first require order-preserving storage; reject binary + decimal, allow string" do
      assert Aggregate.guard_field(agg(:min, field: :amount), @types) == :ok
      assert Aggregate.guard_field(agg(:max, field: :name), @types) == :ok

      assert {:error, {:unaggregatable, :secret, :min}} =
               Aggregate.guard_field(agg(:min, field: :secret), @types)

      assert {:error, {:unaggregatable, :price, :first}} =
               Aggregate.guard_field(agg(:first, field: :price), @types)
    end

    test "list rejects binary (ciphertext leak), allows non-binary incl. decimal" do
      assert Aggregate.guard_field(agg(:list, field: :price), @types) == :ok

      assert {:error, {:unaggregatable, :secret, :list}} =
               Aggregate.guard_field(agg(:list, field: :secret), @types)
    end

    test "exists is always allowed (reads only presence)" do
      assert Aggregate.guard_field(agg(:exists), @types) == :ok
    end

    test "a non-atom field (expression aggregate) fails closed value-free, never inspecting the struct" do
      calc = %Ash.Query.Calculation{
        name: :c,
        module: SomeMod,
        opts: [],
        type: nil,
        constraints: []
      }

      assert {:error, :expression_field} = Aggregate.guard_field(agg(:sum, field: calc), @types)
    end

    test "custom kind is rejected value-free" do
      assert {:error, {:unsupported_kind, :custom}} =
               Aggregate.guard_field(agg(:custom, field: :amount), @types)
    end

    test "a value-reading kind over an unknown field (not in the type map) fails closed value-free" do
      assert {:error, {:unaggregatable, :ghost, :sum}} =
               Aggregate.guard_field(agg(:sum, field: :ghost), @types)
    end

    test "custom kind wins over the non-atom-field branch" do
      calc = %Ash.Query.Calculation{
        name: :c,
        module: SomeMod,
        opts: [],
        type: nil,
        constraints: []
      }

      assert {:error, {:unsupported_kind, :custom}} =
               Aggregate.guard_field(agg(:custom, field: calc), @types)
    end
  end

  describe "return_expr/2 — per-kind Cypher honoring field/uniq? (§6.2)" do
    test "count: bare / field / uniq?" do
      assert {"count(n) AS agg0", _} = Aggregate.return_expr(agg(:count), "agg0")

      assert {"count(n.amount) AS agg0", _} =
               Aggregate.return_expr(agg(:count, field: :amount), "agg0")

      assert {"count(DISTINCT n.amount) AS agg0", _} =
               Aggregate.return_expr(agg(:count, field: :amount, uniq?: true), "agg0")
    end

    test "sum/avg/min/max carry a count companion for empty-set disambiguation" do
      assert {"sum(n.amount) AS agg0, count(n) AS agg0_card", :companion} =
               Aggregate.return_expr(agg(:sum, field: :amount), "agg0")

      assert {"avg(n.amount) AS agg0, count(n) AS agg0_card", :companion} =
               Aggregate.return_expr(agg(:avg, field: :amount), "agg0")

      assert {"min(n.amount) AS agg0, count(n) AS agg0_card", :companion} =
               Aggregate.return_expr(agg(:min, field: :amount), "agg0")
    end

    test "list: collect / uniq? collect DISTINCT, no companion (empty→[])" do
      assert {"collect(n.name) AS agg0", :plain} =
               Aggregate.return_expr(agg(:list, field: :name), "agg0")

      assert {"collect(DISTINCT n.name) AS agg0", :plain} =
               Aggregate.return_expr(agg(:list, field: :name, uniq?: true), "agg0")
    end

    test "exists: count>0, no companion" do
      assert {"count(n) > 0 AS agg0", :plain} = Aggregate.return_expr(agg(:exists), "agg0")
    end
  end
end
