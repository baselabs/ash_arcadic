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
      offset: 5,
      limit: 10
    }

    {cypher, params} = Query.to_cypher(q)

    # With no distinct_sort, the representative order falls back to the QUERY SORT
    # (Ash contract, deps/ash query.ex:4285: "If none is set, any sort applied to the
    # query will be used") — never the distinct fields (a within-group no-op).
    assert cypher ==
             "MATCH (n:Person) WITH n ORDER BY n.age DESC " <>
               "WITH n.name AS __d0, collect(n)[0] AS n " <>
               "RETURN n ORDER BY n.age DESC SKIP 5 LIMIT 10"

    assert params == %{}
  end

  test "distinct honors distinct_sort for representative selection, taking priority over the query sort" do
    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      distinct: [{:name, :asc}, {:age, :asc}],
      distinct_sort: [{:age, :desc}],
      sort: [{:name, :asc}]
    }

    {cypher, _params} = Query.to_cypher(q)

    assert cypher ==
             "MATCH (n:Person) WITH n ORDER BY n.age DESC " <>
               "WITH n.name AS __d0, n.age AS __d1, collect(n)[0] AS n " <>
               "RETURN n ORDER BY n.name ASC"
  end

  test "distinct with neither distinct_sort nor query sort elides the representative ORDER BY stage" do
    # No order can select a representative (Ash promises none absent a sort) — the render
    # drops the interposed `WITH n ORDER BY` entirely (the bare collect-group is the
    # probe-confirmed spec §2 shape) instead of paying a no-op DB-side sort.
    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      distinct: [{:name, :asc}]
    }

    {cypher, params} = Query.to_cypher(q)

    assert cypher == "MATCH (n:Person) WITH n.name AS __d0, collect(n)[0] AS n RETURN n"
    assert params == %{}
  end

  test "a struct distinct entry reaching the render raises a value-free ArgumentError (backstop)" do
    # The data-layer distinct/3 guard rejects calc/struct entries BEFORE the render; this pins the
    # render's own defense-in-depth: Identifier.validate!'s catch-all raises value-free.
    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      distinct: [{struct(Ash.Query.Calculation, name: :fullname), :asc}]
    }

    err = assert_raise ArgumentError, fn -> Query.to_cypher(q) end
    assert err.message =~ "invalid ArcadeDB identifier"
    refute err.message =~ "fullname"
    refute err.message =~ "Calculation"
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
             "MATCH (n:Person) WHERE n.name = $param1 " <>
               "WITH n.name AS __d0, collect(n)[0] AS n RETURN n"

    assert params == %{"param1" => "Ann"}
  end

  test "native combination renders CALL{UNION} with re-keyed branch params + outer WHERE/ORDER/LIMIT" do
    b0 = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      filters: ["n.name = $param1"],
      params: %{"param1" => "Ada"}
    }

    b1 = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      filters: ["n.age = $param1"],
      params: %{"param1" => 30}
    }

    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      combination_of: [{:base, b0}, {:union, b1}],
      filters: ["n.org = $param1"],
      params: %{"param1" => "acme"},
      sort: [{:name, :desc}],
      limit: 5
    }

    {cypher, params} = Query.to_cypher(q)

    assert cypher ==
             "CALL { MATCH (n:Person) WHERE n.name = $b0_param1 RETURN n " <>
               "UNION MATCH (n:Person) WHERE n.age = $b1_param1 RETURN n } " <>
               "WITH n WHERE n.org = $param1 RETURN n ORDER BY n.name DESC LIMIT 5"

    assert params == %{"b0_param1" => "Ada", "b1_param1" => 30, "param1" => "acme"}
  end

  test "native combination with :union_all uses UNION ALL; outer distinct adds the collect-group" do
    b0 = %Query{resource: AshArcadic.Test.Basic, label: :Person, filters: [], params: %{}}
    b1 = %Query{resource: AshArcadic.Test.Basic, label: :Person, filters: [], params: %{}}

    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      combination_of: [{:base, b0}, {:union_all, b1}],
      distinct: [{:name, :asc}]
    }

    {cypher, _} = Query.to_cypher(q)

    assert cypher ==
             "CALL { MATCH (n:Person) RETURN n UNION ALL MATCH (n:Person) RETURN n } " <>
               "WITH n WITH n.name AS __d0, collect(n)[0] AS n RETURN n"
  end

  test "a branch carrying its own paging is wrapped in an inner CALL{}" do
    b0 = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      filters: [],
      params: %{},
      sort: [{:age, :asc}],
      limit: 1
    }

    b1 = %Query{resource: AshArcadic.Test.Basic, label: :Person, filters: [], params: %{}}

    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      combination_of: [{:base, b0}, {:union, b1}]
    }

    {cypher, _} = Query.to_cypher(q)

    assert cypher ==
             "CALL { CALL { MATCH (n:Person) RETURN n ORDER BY n.age ASC LIMIT 1 } RETURN n " <>
               "UNION MATCH (n:Person) RETURN n } WITH n RETURN n"
  end

  test "native 3-branch chain joins each branch's operator left-to-right (UNION then UNION ALL)" do
    b0 = %Query{resource: AshArcadic.Test.Basic, label: :Person, filters: [], params: %{}}
    b1 = %Query{resource: AshArcadic.Test.Basic, label: :Person, filters: [], params: %{}}
    b2 = %Query{resource: AshArcadic.Test.Basic, label: :Person, filters: [], params: %{}}

    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      combination_of: [{:base, b0}, {:union, b1}, {:union_all, b2}]
    }

    {cypher, _} = Query.to_cypher(q)

    assert cypher ==
             "CALL { MATCH (n:Person) RETURN n UNION MATCH (n:Person) RETURN n " <>
               "UNION ALL MATCH (n:Person) RETURN n } WITH n RETURN n"
  end

  test "native combination with multi-field outer distinct comma-joins the with-keys" do
    b0 = %Query{resource: AshArcadic.Test.Basic, label: :Person, filters: [], params: %{}}
    b1 = %Query{resource: AshArcadic.Test.Basic, label: :Person, filters: [], params: %{}}

    q = %Query{
      resource: AshArcadic.Test.Basic,
      label: :Person,
      combination_of: [{:base, b0}, {:union, b1}],
      distinct: [{:name, :asc}, {:age, :desc}]
    }

    {cypher, _} = Query.to_cypher(q)

    assert cypher ==
             "CALL { MATCH (n:Person) RETURN n UNION MATCH (n:Person) RETURN n } " <>
               "WITH n WITH n.name AS __d0, n.age AS __d1, collect(n)[0] AS n RETURN n"
  end
end
