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
  end
end
