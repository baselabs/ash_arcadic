defmodule AshArcadic.Query.CombinationTest do
  use ExUnit.Case, async: true

  alias AshArcadic.Query.Combination

  defp rec(id, name), do: %{id: id, name: name}

  test "native? is true only when every branch type is union-family" do
    assert Combination.native?([{:base, :q}, {:union, :q}, {:union_all, :q}])
    refute Combination.native?([{:base, :q}, {:intersect, :q}])
    refute Combination.native?([{:base, :q}, {:except, :q}])
  end

  test "combine folds union/union_all/intersect/except by primary key, left to right" do
    a = [rec("1", "a"), rec("2", "b")]
    b = [rec("2", "b2"), rec("3", "c")]

    assert Combination.combine([{:base, a}, {:union, b}], [:id]) |> Enum.map(& &1.id) == [
             "1",
             "2",
             "3"
           ]

    assert Combination.combine([{:base, a}, {:union_all, b}], [:id]) |> Enum.map(& &1.id) == [
             "1",
             "2",
             "2",
             "3"
           ]

    assert Combination.combine([{:base, a}, {:intersect, b}], [:id]) |> Enum.map(& &1.id) == ["2"]
    assert Combination.combine([{:base, a}, {:except, b}], [:id]) |> Enum.map(& &1.id) == ["1"]
  end

  test "combine keys composite primary keys" do
    a = [%{k1: "x", k2: 1}, %{k1: "x", k2: 2}]
    b = [%{k1: "x", k2: 2}]
    assert Combination.combine([{:base, a}, {:intersect, b}], [:k1, :k2]) == [%{k1: "x", k2: 2}]
  end

  test "combine threads the accumulator left-to-right across a 3-op chain" do
    # base=[1,2,3]; ++union_all([3,4])→[1,2,3,3,4]; except([2,4]) removes id∈{2,4}→[1,3,3].
    base = [rec("1", "a"), rec("2", "b"), rec("3", "c")]
    ua = [rec("3", "c2"), rec("4", "d")]
    ex = [rec("2", "b3"), rec("4", "d3")]

    result =
      Combination.combine([{:base, base}, {:union_all, ua}, {:except, ex}], [:id])

    assert Enum.map(result, & &1.id) == ["1", "3", "3"]
  end

  test "combine fails closed (raises) on a mid-chain :base branch" do
    assert_raise ArgumentError, fn ->
      Combination.combine(
        [{:base, [rec("1", "a")]}, {:union, [rec("2", "b")]}, {:base, [rec("9", "z")]}],
        [:id]
      )
    end
  end

  test "rekey_branch namespaces params + rewrites clauses; $param1 in the SAME clause is not clobbered by $param10" do
    # Adversarial: both refs in ONE clause. A naive shortest-first String.replace would rewrite the
    # `$param1` prefix inside `$param10` first, producing `$b2_param10` → `$b2_param1`0. Longest-key-first
    # (rekey_branch sorts keys by byte_size desc) rewrites `$param10` before `$param1`, keeping both intact.
    filters = ["n.a = $param1 AND n.b = $param10"]
    params = %{"param1" => "Ann", "param10" => 42}

    {rk_filters, rk_params} = Combination.rekey_branch(filters, params, 2)

    assert rk_filters == ["n.a = $b2_param1 AND n.b = $b2_param10"]
    assert rk_params == %{"b2_param1" => "Ann", "b2_param10" => 42}
  end

  test "combine raises value-free (not a record-carrying FunctionClauseError) on a non-:base first branch" do
    err =
      assert_raise ArgumentError, fn ->
        Combination.combine([{:union, [rec("secretid", "secretname")]}], [:id])
      end

    assert Exception.message(err) =~ "first branch must be :base"
    refute Exception.message(err) =~ "secret"
  end
end
