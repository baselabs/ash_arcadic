defmodule AshArcadic.DataLayer.SkeletonTest do
  use ExUnit.Case, async: true
  alias AshArcadic.DataLayer.Info

  test "a resource using AshArcadic.DataLayer compiles and exposes its DSL" do
    assert Info.client(AshArcadic.Test.Basic) == AshArcadic.Test.MockClient
    assert Info.label(AshArcadic.Test.Basic) == :Person
    assert Info.sensitive(AshArcadic.Test.Basic) == [:secret]
  end

  test "attribute_map excludes skipped attrs; attribute_types carries {type, constraints}" do
    # Basic declares `skip [:computed]`, so :computed must NOT appear in the map.
    # The `==` (not loose `=`) pins the full map, and the `refute` is the tripwire:
    # deleting `Info.attribute_map/1`'s `Enum.reject(&(&1.name in skip))` guard would
    # let :computed through and fail this test.
    assert Info.attribute_map(AshArcadic.Test.Basic) == %{
             id: "id",
             name: "name",
             secret: "secret",
             age: "age",
             amount: "amount"
           }

    refute Map.has_key?(Info.attribute_map(AshArcadic.Test.Basic), :computed)
    assert {Ash.Type.String, _} = Map.fetch!(Info.attribute_types(AshArcadic.Test.Basic), :name)
  end

  test "resource_to_query returns an %AshArcadic.Query{} carrying resource/client/label" do
    q = AshArcadic.DataLayer.resource_to_query(AshArcadic.Test.Basic, AshArcadic.Test.Domain)

    assert %AshArcadic.Query{
             resource: AshArcadic.Test.Basic,
             client: AshArcadic.Test.MockClient,
             label: :Person
           } = q
  end

  test "can?/2: read + multitenancy + transact + traverse supported (Plans 3–4)" do
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :multitenancy)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :read)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :transact)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :traverse)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :distinct)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :distinct_sort)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :combine)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:combine, :base})
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:combine, :union})
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:combine, :intersect})
    refute AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:combine, :bogus})
    # Slice 9: query-scoped bulk-write push-down + expression-error surfacing.
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :update_query)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :expr_error)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :destroy_query)
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, :update_many)
    # Slice 9: atomic SET on create/upsert (V8) + the pure :atomic bulk-update strategy.
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:atomic, :update})
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:atomic, :create})
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:atomic, :upsert})
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:query_aggregate, :count})
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:query_aggregate, :sum})
    # Slice 4: relationship aggregates enabled; flat/unrelated inline aggregates REFUSED
    # ({:aggregate,:unrelated}=false → Ash rejects flat inline upstream, so add_aggregate only
    # ever gets relationship aggregates).
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:aggregate, :count})
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:aggregate, :sum})
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:aggregate_relationship, %{}})
    refute AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:aggregate, :unrelated})
    refute AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:aggregate, :custom})
    refute AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:query_aggregate, :custom})
    refute AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:lateral_join, []})

    assert AshArcadic.DataLayer.can?(
             AshArcadic.Test.Basic,
             {:filter_expr, %Ash.Query.Operator.Basic.Plus{}}
           )

    assert AshArcadic.DataLayer.can?(
             AshArcadic.Test.Basic,
             {:filter_expr, %Ash.Query.Operator.Basic.Concat{}}
           )

    # Slice 9: a constant-folded literal ({:filter_expr, 101} after Operator.new evaluates an
    # all-literal call) is always translatable — bound as $paramN.
    assert AshArcadic.DataLayer.can?(AshArcadic.Test.Basic, {:filter_expr, 101})

    # Slice 5: standard (attribute-FK) relationships — filter_relationship enabled for standard
    # rels (has_many/has_one manual: nil; belongs_to/m2m have no :manual key); manual Traverse rels
    # stay false (fail-closed reject, V1).
    assert AshArcadic.DataLayer.can?(
             AshArcadic.Test.Basic,
             {:filter_relationship, %{manual: nil}}
           )

    assert AshArcadic.DataLayer.can?(
             AshArcadic.Test.Basic,
             {:filter_relationship, %{name: :author}}
           )

    refute AshArcadic.DataLayer.can?(
             AshArcadic.Test.Basic,
             {:filter_relationship, %{manual: {AshArcadic.ManualRelationships.Traverse, []}}}
           )
  end

  test "set_context/3 captures private.internal? onto the query (default false when absent)" do
    q = AshArcadic.DataLayer.resource_to_query(AshArcadic.Test.Basic, AshArcadic.Test.Domain)

    {:ok, internal} =
      AshArcadic.DataLayer.set_context(AshArcadic.Test.Basic, q, %{private: %{internal?: true}})

    assert internal.internal? == true

    {:ok, top_level} = AshArcadic.DataLayer.set_context(AshArcadic.Test.Basic, q, %{private: %{}})
    assert top_level.internal? == false
  end
end
