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
