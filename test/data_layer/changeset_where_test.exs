defmodule AshArcadic.DataLayer.ChangesetWhereTest do
  use ExUnit.Case, async: true

  require Ash.Query
  alias AshArcadic.DataLayer, as: DL

  test "a nil changeset filter returns the base clause unchanged" do
    cs = %Ash.Changeset{resource: AshArcadic.Test.Basic, filter: nil}

    assert {:ok, "n.id = $match_id", %{"match_id" => "p1"}} =
             DL.changeset_where(cs, "n.id = $match_id", %{"match_id" => "p1"})
  end

  test "a supported changeset filter AND-composes with the base clause" do
    filter = Ash.Filter.parse!(AshArcadic.Test.Basic, name: "Ann")
    cs = %Ash.Changeset{resource: AshArcadic.Test.Basic, filter: filter}
    # The seed params map already holds `match_id` (size 1), so add_param's
    # collision-skip counter lands on `param2` (next_param_key starts at size+1 = 2).
    {:ok, where, params} = DL.changeset_where(cs, "n.id = $match_id", %{"match_id" => "p1"})
    assert where == "n.id = $match_id AND n.name = $param2"
    assert params == %{"match_id" => "p1", "param2" => "Ann"}
  end

  test "an unsupported changeset filter fails closed (never silently drops scoping)" do
    # An attribute-to-attribute comparison is a reachable UnsupportedFilter (`like`
    # cannot be built — Ash refuses to parse an operator the layer does not advertise).
    filter = Ash.Query.filter(AshArcadic.Test.Basic, name == age).filter
    cs = %Ash.Changeset{resource: AshArcadic.Test.Basic, filter: filter}
    assert {:error, _} = DL.changeset_where(cs, "n.id = $match_id", %{"match_id" => "p1"})
  end
end
