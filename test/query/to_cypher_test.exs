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

  test "ORDER BY honors nil-placement qualifiers (native for defaults, IS-NULL prefix for opposites)" do
    # ArcadeDB native: ASC→nulls-last, DESC→nulls-first (probe-verified), which already matches Ash's
    # default convention (:asc≡:asc_nils_last, :desc≡:desc_nils_first). The explicit OPPOSITE
    # qualifiers (:asc_nils_first, :desc_nils_last) are honored via a leading `(<col> IS NULL)` key.
    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      sort: [
        {:a, :asc},
        {:b, :desc},
        {:c, :asc_nils_last},
        {:d, :desc_nils_first},
        {:e, :asc_nils_first},
        {:f, :desc_nils_last},
        {:expr, "(n.x + n.y)", :asc_nils_first}
      ]
    }

    {cypher, _} = Query.to_cypher(q)

    assert cypher =~
             "ORDER BY n.a ASC, n.b DESC, n.c ASC, n.d DESC, " <>
               "(n.e IS NULL) DESC, n.e ASC, (n.f IS NULL) ASC, n.f DESC, " <>
               "((n.x + n.y) IS NULL) DESC, (n.x + n.y) ASC"
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

  test "distinct on a subset renders the DISTINCT-ON collect-group form, outer ORDER BY after the collect" do
    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      distinct: [{:name, :asc}],
      sort: [{:age, :desc}],
      limit: 10
    }

    {cypher, params} = Query.to_cypher(q)

    assert cypher ==
             "MATCH (n:Person) WITH n ORDER BY n.name ASC " <>
               "WITH n.name AS __d0, collect(n)[0] AS n " <>
               "RETURN n ORDER BY n.age DESC LIMIT 10"

    assert params == %{}
  end

  test "distinct honors distinct_sort for representative selection over the distinct-field order" do
    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      distinct: [{:name, :asc}, {:age, :asc}],
      distinct_sort: [{:age, :desc}]
    }

    {cypher, _params} = Query.to_cypher(q)

    assert cypher ==
             "MATCH (n:Person) WITH n ORDER BY n.age DESC " <>
               "WITH n.name AS __d0, n.age AS __d1, collect(n)[0] AS n RETURN n"
  end

  test "distinct composes with a WHERE clause (filter renders before the WITH)" do
    filter = Ash.Filter.parse!(AshArcadic.Test.Basic, name: "Ann")

    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      expression: filter,
      distinct: [{:name, :asc}]
    }

    {cypher, params} = Query.to_cypher(q)

    assert cypher ==
             "MATCH (n:Person) WHERE n.name = $param1 WITH n ORDER BY n.name ASC " <>
               "WITH n.name AS __d0, collect(n)[0] AS n RETURN n"

    assert params == %{"param1" => "Ann"}
  end
end
