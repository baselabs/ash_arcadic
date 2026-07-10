defmodule AshArcadic.DataLayer.CombinationPrepareTest do
  use ExUnit.Case, async: true

  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Query

  test ":context — a blank-tenant branch (nil database) fails closed value-free" do
    branch = %Query{resource: AshArcadic.Test.ContextDoc, database: nil}

    assert {:error, err} =
             DL.combination_of([{:base, branch}], AshArcadic.Test.ContextDoc, nil)

    assert Exception.message(err) =~ "tenant"
  end

  test ":context — branches resolving to DIFFERENT tenant databases fail closed" do
    b0 = %Query{resource: AshArcadic.Test.ContextDoc, database: "db_a"}
    b1 = %Query{resource: AshArcadic.Test.ContextDoc, database: "db_b"}

    assert {:error, err} =
             DL.combination_of([{:base, b0}, {:union, b1}], AshArcadic.Test.ContextDoc, nil)

    assert Exception.message(err) =~ "multiple"
  end

  test ":context — uniform non-nil database is accepted; combined query carries it" do
    b0 = %Query{resource: AshArcadic.Test.ContextDoc, database: "db_a"}
    b1 = %Query{resource: AshArcadic.Test.ContextDoc, database: "db_a"}

    assert {:ok, %Query{database: "db_a", combination_of: [_, _]}} =
             DL.combination_of([{:base, b0}, {:union, b1}], AshArcadic.Test.ContextDoc, nil)
  end

  test ":attribute — branches pass through unchanged (tenant scoping rides the outer query.filters)" do
    # No per-branch mutation: the :attribute tenant predicate is Ash's job (outer query.filters),
    # applied downstream by to_cypher / run_branch. combination_of/3 just carries the branches.
    branch = %Query{
      resource: AshArcadic.Test.AttributeDoc,
      tenant: "org7",
      filters: ["n.name = $param1"],
      params: %{"param1" => "x"}
    }

    assert {:ok, %Query{database: nil, combination_of: [{:base, b0}, {:union, b1}]}} =
             DL.combination_of(
               [{:base, branch}, {:union, branch}],
               AshArcadic.Test.AttributeDoc,
               nil
             )

    # unchanged — combination_of/3 adds NO org_id predicate (it lives in the outer query.filters)
    assert b0.filters == ["n.name = $param1"]
    assert b1.filters == ["n.name = $param1"]
    assert b0.params == %{"param1" => "x"}
    assert b1.params == %{"param1" => "x"}
  end

  test ":context — an empty-string database (blank tenant) fails closed" do
    branch = %Query{resource: AshArcadic.Test.ContextDoc, database: ""}

    assert {:error, err} =
             DL.combination_of([{:base, branch}], AshArcadic.Test.ContextDoc, nil)

    assert Exception.message(err) =~ "tenant"
  end

  test ":context — a later branch going blank fails closed (blank wins over span)" do
    b0 = %Query{resource: AshArcadic.Test.ContextDoc, database: "db_a"}
    b1 = %Query{resource: AshArcadic.Test.ContextDoc, database: "db_a"}
    b2 = %Query{resource: AshArcadic.Test.ContextDoc, database: nil}

    assert {:error, err} =
             DL.combination_of(
               [{:base, b0}, {:union, b1}, {:union, b2}],
               AshArcadic.Test.ContextDoc,
               nil
             )

    assert Exception.message(err) =~ "required"
  end
end
