defmodule AshArcadic.DataLayer.QueryBuildingTest do
  use ExUnit.Case, async: true

  require Ash.Query
  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Query

  test "sort/limit/offset accumulate onto the query struct" do
    q = %Query{resource: AshArcadic.Test.Basic}
    {:ok, q} = DL.sort(q, [{:name, :asc}], AshArcadic.Test.Basic)
    {:ok, q} = DL.limit(q, 10, AshArcadic.Test.Basic)
    {:ok, q} = DL.offset(q, 5, AshArcadic.Test.Basic)
    assert q.sort == [{:name, :asc}]
    assert q.limit == 10
    assert q.offset == 5
  end

  test "sort normalizes the %Ash.Resource.Attribute{} struct form Ash passes at runtime" do
    q = %Query{resource: AshArcadic.Test.Basic}
    {:ok, q} = DL.sort(q, [{%Ash.Resource.Attribute{name: :name}, :desc}], AshArcadic.Test.Basic)
    assert q.sort == [{:name, :desc}]
  end

  test "sort rejects a SKIPPED attribute value-free (declared but not a stored property)" do
    # Basic declares `arcade do skip [:computed] end` → :computed is NOT an ArcadeDB property.
    # ORDER BY n.computed would sort by a non-existent property (null → arbitrary order); fail closed.
    q = %Query{resource: AshArcadic.Test.Basic}

    assert {:error, %AshArcadic.Errors.QueryFailed{} = err} =
             DL.sort(q, [{:computed, :asc}], AshArcadic.Test.Basic)

    assert Exception.message(err) =~ "computed"
    assert Exception.message(err) =~ "not a stored attribute"
  end

  test "sort rejects a non-attribute (calculation/aggregate name) sort field value-free" do
    # A bare atom that names a calculation/aggregate (not a declared attribute) is not a
    # stored property either — same silent-mis-order hazard, same fail-closed rejection.
    q = %Query{resource: AshArcadic.Test.Basic}

    assert {:error, %AshArcadic.Errors.QueryFailed{}} =
             DL.sort(q, [{:not_a_real_attribute, :desc}], AshArcadic.Test.Basic)
  end

  test "sort rejects an unknown direction qualifier value-free (sibling parity with the distinct clamp)" do
    # The Ash API path is upstream-gated (Sort.process raises InvalidSortOrder); this pins the
    # DIRECT data-layer ingress so a bogus direction is never silently coerced to ASC by the
    # render's order_dir catch-all (closeout enhancement: after guarding one branch, check siblings).
    q = %Query{resource: AshArcadic.Test.Basic}

    assert {:error, %AshArcadic.Errors.QueryFailed{} = err} =
             DL.sort(q, [{:name, :bogus}], AshArcadic.Test.Basic)

    refute Exception.message(err) =~ "bogus"
  end

  test "filter translates and appends a pre-built clause + params" do
    filter = Ash.Query.filter(AshArcadic.Test.Basic, name == "Ann").filter
    {:ok, q} = DL.filter(%Query{resource: AshArcadic.Test.Basic}, filter, AshArcadic.Test.Basic)
    assert q.filters == ["n.name = $param1"]
    assert q.params == %{"param1" => "Ann"}
  end

  test "filter propagates an UnsupportedFilter error (fails closed, never drops scoping)" do
    filter = Ash.Query.filter(AshArcadic.Test.Basic, name == age).filter

    assert {:error, %AshArcadic.Errors.UnsupportedFilter{}} =
             DL.filter(%Query{resource: AshArcadic.Test.Basic}, filter, AshArcadic.Test.Basic)
  end

  test "set_context captures the private tenant for any strategy" do
    {:ok, q} =
      DL.set_context(AshArcadic.Test.Basic, %Query{resource: AshArcadic.Test.Basic}, %{
        private: %{tenant: "acme"}
      })

    assert q.tenant == "acme"
  end
end
