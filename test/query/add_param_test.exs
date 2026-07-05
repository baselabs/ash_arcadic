defmodule AshArcadic.Query.AddParamTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Query

  test "add_param assigns sequential $paramN references" do
    q0 = %Query{resource: Foo}
    {q1, ref1} = Query.add_param(q0, "a")
    {q2, ref2} = Query.add_param(q1, "b")
    assert ref1 == "$param1"
    assert ref2 == "$param2"
    assert q2.params == %{"param1" => "a", "param2" => "b"}
  end

  test "add_param skips a param name already present (no clobber of a seeded key)" do
    q0 = %Query{resource: Foo, params: %{"param1" => "seeded"}}
    {q1, ref} = Query.add_param(q0, "x")
    assert ref == "$param2"
    assert q1.params == %{"param1" => "seeded", "param2" => "x"}
  end
end
