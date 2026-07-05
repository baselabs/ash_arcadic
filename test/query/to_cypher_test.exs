defmodule AshArcadic.Query.ToCypherTest do
  use ExUnit.Case, async: true

  require Ash.Query
  alias AshArcadic.Query

  test "bare MATCH … RETURN n for a label with no clauses" do
    q = %Query{resource: AshArcadic.Test.Basic, label: :Person}
    assert {"MATCH (n:Person) RETURN n", %{}} = Query.to_cypher(q)
  end

  test "compiles an expression into WHERE, plus ORDER BY / SKIP / LIMIT" do
    filter = Ash.Filter.parse!(AshArcadic.Test.Basic, name: "Ann")

    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      expression: filter,
      sort: [{:name, :asc}, {:age, :desc}],
      offset: 5,
      limit: 10
    }

    {cypher, params} = Query.to_cypher(q)

    assert cypher ==
             "MATCH (n:Person) WHERE n.name = $param1 RETURN n ORDER BY n.name ASC, n.age DESC SKIP 5 LIMIT 10"

    assert params == %{"param1" => "Ann"}
  end

  test "pre-built filter clauses (update/destroy scoping) AND-compose before the expression" do
    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      filters: ["n.id = $match_id"],
      params: %{"match_id" => "p1"}
    }

    assert {"MATCH (n:Person) WHERE n.id = $match_id RETURN n", %{"match_id" => "p1"}} =
             Query.to_cypher(q)
  end

  test "an invalid label raises a value-free ArgumentError (defense-in-depth)" do
    q = %Query{resource: AshArcadic.Test.Basic, label: "1bad; MATCH"}
    err = assert_raise ArgumentError, fn -> Query.to_cypher(q) end
    refute err.message =~ "MATCH"
  end

  test "FAIL-CLOSED: an unsupported expression raises value-free, never a silent unscoped read" do
    # A decimal range op is rejected by Filter.translate (D27). Routed through
    # `expression`, to_cypher must RAISE — never silently drop the WHERE and return
    # an unscoped `MATCH (n:Person) RETURN n`.
    filter = Ash.Query.filter(AshArcadic.Test.Basic, amount > ^Decimal.new("1.00")).filter
    q = %Query{resource: AshArcadic.Test.Basic, label: :Person, expression: filter}

    err = assert_raise AshArcadic.Errors.UnsupportedFilter, fn -> Query.to_cypher(q) end
    refute Exception.message(err) =~ "1.00"
  end
end
