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

  test "traverse is true (Plan 4)" do
    assert DL.can?(AshArcadic.Test.Basic, :traverse)
  end

  test "query + relationship aggregates advertised per kind ({:aggregate, kind} + {:aggregate_relationship}); flat/unrelated + lateral_join stay false" do
    for kind <- [:count, :sum, :avg, :min, :max, :first, :list, :exists] do
      assert DL.can?(AshArcadic.Test.Basic, {:query_aggregate, kind}),
             "expected can?({:query_aggregate, #{kind}})"
    end

    refute DL.can?(AshArcadic.Test.Basic, {:query_aggregate, :custom})

    # Slice 4: relationship aggregates enabled (compile gate + per-kind); flat/unrelated REFUSED.
    for kind <- [:count, :sum, :avg, :min, :max, :first, :list, :exists] do
      assert DL.can?(AshArcadic.Test.Basic, {:aggregate, kind}),
             "expected can?({:aggregate, #{kind}}) for relationship aggregates"
    end

    assert DL.can?(AshArcadic.Test.Basic, {:aggregate_relationship, %{}})
    refute DL.can?(AshArcadic.Test.Basic, {:aggregate, :unrelated})
    refute DL.can?(AshArcadic.Test.Basic, {:aggregate, :custom})
    refute DL.can?(AshArcadic.Test.Basic, {:lateral_join, []})
  end

  test "sort allowed except on binary and decimal storage (unorderable)" do
    assert DL.can?(AshArcadic.Test.Basic, {:sort, :string})
    assert DL.can?(AshArcadic.Test.Basic, {:sort, :integer})
    refute DL.can?(AshArcadic.Test.Basic, {:sort, :binary})
    refute DL.can?(AshArcadic.Test.Basic, {:sort, :decimal})
  end

  test "filter_expr: supported operators + string-match + boolean/not + calc value-ops true; unknown false" do
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
          %Ash.Query.Not{},
          %Ash.Query.Operator.Basic.Plus{},
          %Ash.Query.Operator.Basic.Minus{},
          %Ash.Query.Operator.Basic.Times{},
          %Ash.Query.Operator.Basic.Div{},
          %Ash.Query.Operator.Basic.Concat{},
          %Ash.Query.Function.If{},
          %Ash.Query.Function.IsNil{},
          %Ash.Query.Function.StringDowncase{},
          %Ash.Query.Function.StringLength{},
          %Ash.Query.Function.StringTrim{},
          %Ash.Query.Function.Round{}
        ] do
      assert DL.can?(AshArcadic.Test.Basic, {:filter_expr, s}),
             "expected can?({:filter_expr, #{inspect(s.__struct__)}})"
    end

    # A date/time function stays unsupported (non-goal — ISO8601 storage; §9).
    refute DL.can?(AshArcadic.Test.Basic, {:filter_expr, %Ash.Query.Function.Ago{}})
  end

  test "filter_relationship: true for STANDARD rels (any type), false for MANUAL Traverse rels (V1 fail-closed)" do
    # has_many/has_one carry manual: nil (standard). belongs_to and many_to_many have NO :manual
    # field (Map.get → nil). ALL are STANDARD → filterable via Ash's separate-read IN path (join
    # stays false). A manual Traverse rel carries manual: {mod, opts} → NOT filterable: Ash rejects
    # the filter clean ("not filterable"), NOT routed to an unauthorized IN-rewrite over the traversal
    # destination (V1). The clause keys off the VALUE (is_nil(Map.get(rel, :manual))), not key-presence.
    assert DL.can?(AshArcadic.Test.Basic, {:filter_relationship, %{manual: nil}})

    # belongs_to / many_to_many shape — NO :manual key. Must still be filterable (regression pin for
    # the %{manual: nil}-pattern bug the plan reviewer caught).
    assert DL.can?(AshArcadic.Test.Basic, {:filter_relationship, %{name: :author}})

    refute DL.can?(
             AshArcadic.Test.Basic,
             {:filter_relationship, %{manual: {AshArcadic.ManualRelationships.Traverse, []}}}
           )

    # join / lateral_join stay false — routes standard-rel filters to the separate-read path.
    refute DL.can?(AshArcadic.Test.Basic, {:join, AshArcadic.Test.Basic})
    refute DL.can?(AshArcadic.Test.Basic, {:lateral_join, []})
  end

  test "filter_relationship fails closed on a policy-bearing destination (Slice-5 amendment)" do
    refute DL.can?(
             AshArcadic.Test.RelPost,
             {:filter_relationship, %{manual: nil, destination: AshArcadic.Test.RelAuthor}}
           )

    assert DL.can?(
             AshArcadic.Test.RelPost,
             {:filter_relationship, %{manual: nil, destination: AshArcadic.Test.RelPlainAuthor}}
           )

    assert DL.can?(AshArcadic.Test.Basic, {:filter_relationship, %{manual: nil}})
  end
end
