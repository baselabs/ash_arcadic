defmodule AshArcadic.DataLayer.CanTest do
  use ExUnit.Case, async: true
  alias AshArcadic.DataLayer, as: DL

  test "read + write + query-building capabilities are advertised" do
    for feature <- [
          :read,
          :create,
          :update,
          :destroy,
          :upsert,
          :bulk_create,
          :filter,
          :limit,
          :offset,
          :sort,
          :boolean_filter,
          :nested_expressions,
          :multitenancy,
          :composite_primary_key,
          :changeset_filter
        ] do
      assert DL.can?(AshArcadic.Test.Basic, feature), "expected can?(#{feature})"
    end
  end

  test "transact is true (Plan 3)" do
    assert DL.can?(AshArcadic.Test.Basic, :transact)
  end

  test "aggregates/lateral_join false" do
    refute DL.can?(AshArcadic.Test.Basic, {:aggregate, :count})
    refute DL.can?(AshArcadic.Test.Basic, {:lateral_join, []})
  end

  test "sort allowed except on binary and decimal storage (unorderable)" do
    assert DL.can?(AshArcadic.Test.Basic, {:sort, :string})
    assert DL.can?(AshArcadic.Test.Basic, {:sort, :integer})
    refute DL.can?(AshArcadic.Test.Basic, {:sort, :binary})
    refute DL.can?(AshArcadic.Test.Basic, {:sort, :decimal})
  end

  test "filter_expr: supported operators + string-match + boolean/not true; unknown false" do
    for s <- [
          %Ash.Query.Operator.Eq{},
          %Ash.Query.Operator.NotEq{},
          %Ash.Query.Operator.In{},
          %Ash.Query.Operator.IsNil{},
          %Ash.Query.Operator.GreaterThan{},
          %Ash.Query.Operator.LessThan{},
          %Ash.Query.Operator.GreaterThanOrEqual{},
          %Ash.Query.Operator.LessThanOrEqual{},
          %Ash.Query.Function.Contains{},
          %Ash.Query.Function.StringStartsWith{},
          %Ash.Query.Function.StringEndsWith{},
          %Ash.Query.BooleanExpression{op: :and},
          %Ash.Query.Not{}
        ] do
      assert DL.can?(AshArcadic.Test.Basic, {:filter_expr, s}),
             "expected can?({:filter_expr, #{inspect(s.__struct__)}})"
    end

    refute DL.can?(AshArcadic.Test.Basic, {:filter_expr, %Ash.Query.Function.If{}})
  end
end
