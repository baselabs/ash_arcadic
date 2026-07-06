defmodule AshArcadic.AggregateTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Aggregate

  # {type, constraints} specs by attribute name for the guard/decode.
  @types %{
    amount: {Ash.Type.Integer, []},
    price: {Ash.Type.Decimal, []},
    secret: {Ash.Type.Binary, []},
    name: {Ash.Type.String, []}
  }

  defp agg(kind, opts \\ []) do
    struct(
      Ash.Query.Aggregate,
      Keyword.merge([name: :agg, kind: kind, field: nil, uniq?: false], opts)
    )
  end

  describe "guard_field/2 — value-free correctness + leak guard (§6.4)" do
    test "count is always allowed (any field / no field / uniq?)" do
      assert Aggregate.guard_field(agg(:count), @types) == :ok
      assert Aggregate.guard_field(agg(:count, field: :secret), @types) == :ok
      assert Aggregate.guard_field(agg(:count, field: :amount, uniq?: true), @types) == :ok
    end

    test "sum/avg require numeric storage; reject decimal/binary/string" do
      assert Aggregate.guard_field(agg(:sum, field: :amount), @types) == :ok

      assert {:error, {:unaggregatable, :price, :sum}} =
               Aggregate.guard_field(agg(:sum, field: :price), @types)

      assert {:error, {:unaggregatable, :secret, :avg}} =
               Aggregate.guard_field(agg(:avg, field: :secret), @types)
    end

    test "min/max/first require order-preserving storage; reject binary + decimal, allow string" do
      assert Aggregate.guard_field(agg(:min, field: :amount), @types) == :ok
      assert Aggregate.guard_field(agg(:max, field: :name), @types) == :ok

      assert {:error, {:unaggregatable, :secret, :min}} =
               Aggregate.guard_field(agg(:min, field: :secret), @types)

      assert {:error, {:unaggregatable, :price, :first}} =
               Aggregate.guard_field(agg(:first, field: :price), @types)
    end

    test "list rejects binary (ciphertext leak), allows non-binary incl. decimal" do
      assert Aggregate.guard_field(agg(:list, field: :price), @types) == :ok

      assert {:error, {:unaggregatable, :secret, :list}} =
               Aggregate.guard_field(agg(:list, field: :secret), @types)
    end

    test "exists is always allowed (reads only presence)" do
      assert Aggregate.guard_field(agg(:exists), @types) == :ok
    end

    test "a non-atom field (expression aggregate) fails closed value-free, never inspecting the struct" do
      calc = %Ash.Query.Calculation{
        name: :c,
        module: SomeMod,
        opts: [],
        type: nil,
        constraints: []
      }

      assert {:error, :expression_field} = Aggregate.guard_field(agg(:sum, field: calc), @types)
    end

    test "custom kind is rejected value-free" do
      assert {:error, {:unsupported_kind, :custom}} =
               Aggregate.guard_field(agg(:custom, field: :amount), @types)
    end

    test "a value-reading kind over an unknown field (not in the type map) fails closed value-free" do
      assert {:error, {:unaggregatable, :ghost, :sum}} =
               Aggregate.guard_field(agg(:sum, field: :ghost), @types)
    end

    test "custom kind wins over the non-atom-field branch" do
      calc = %Ash.Query.Calculation{
        name: :c,
        module: SomeMod,
        opts: [],
        type: nil,
        constraints: []
      }

      assert {:error, {:unsupported_kind, :custom}} =
               Aggregate.guard_field(agg(:custom, field: calc), @types)
    end

    test "include_nil?: true on list/first fails closed value-free (§6.5 — collect drops nulls)" do
      assert {:error, {:include_nil_unsupported, :list}} =
               Aggregate.guard_field(agg(:list, field: :name, include_nil?: true), @types)

      assert {:error, {:include_nil_unsupported, :first}} =
               Aggregate.guard_field(agg(:first, field: :amount, include_nil?: true), @types)

      # include_nil?: false (the default) is unaffected — list/first still pass their storage guard.
      assert Aggregate.guard_field(agg(:list, field: :name, include_nil?: false), @types) == :ok

      assert Aggregate.guard_field(agg(:first, field: :amount, include_nil?: false), @types) ==
               :ok
    end
  end

  describe "return_expr/2 — per-kind Cypher honoring field/uniq? (§6.2)" do
    test "count: bare / field / uniq?" do
      assert {"count(n) AS agg0", _} = Aggregate.return_expr(agg(:count), "agg0")

      assert {"count(n.amount) AS agg0", _} =
               Aggregate.return_expr(agg(:count, field: :amount), "agg0")

      assert {"count(DISTINCT n.amount) AS agg0", _} =
               Aggregate.return_expr(agg(:count, field: :amount, uniq?: true), "agg0")
    end

    test "sum/avg/min/max carry a count companion for empty-set disambiguation" do
      assert {"sum(n.amount) AS agg0, count(n) AS agg0_card", :companion} =
               Aggregate.return_expr(agg(:sum, field: :amount), "agg0")

      assert {"avg(n.amount) AS agg0, count(n) AS agg0_card", :companion} =
               Aggregate.return_expr(agg(:avg, field: :amount), "agg0")

      assert {"min(n.amount) AS agg0, count(n) AS agg0_card", :companion} =
               Aggregate.return_expr(agg(:min, field: :amount), "agg0")
    end

    test "list: collect / uniq? collect DISTINCT, no companion (empty→[])" do
      assert {"collect(n.name) AS agg0", :plain} =
               Aggregate.return_expr(agg(:list, field: :name), "agg0")

      assert {"collect(DISTINCT n.name) AS agg0", :plain} =
               Aggregate.return_expr(agg(:list, field: :name, uniq?: true), "agg0")
    end

    test "exists: count>0, no companion" do
      assert {"count(n) > 0 AS agg0", :plain} = Aggregate.return_expr(agg(:exists), "agg0")
    end
  end

  describe "build_statement/3 — one statement per aggregate (§6.1)" do
    alias AshArcadic.Query

    defp base_query(filters \\ [], params \\ %{}) do
      %Query{resource: __MODULE__, label: :Person, filters: filters, params: params}
    end

    test "count over the base filter (no field), no companion" do
      q = base_query(["n.t = $param1"], %{"param1" => "org1"})

      assert {:ok, cypher, params} =
               Aggregate.build_statement(q, agg(:count), @types)

      assert cypher == "MATCH (n:Person) WHERE n.t = $param1 RETURN count(n) AS agg0"
      assert params == %{"param1" => "org1"}
    end

    test "sum carries the cardinality companion" do
      assert {:ok, cypher, _} =
               Aggregate.build_statement(base_query(), agg(:sum, field: :amount), @types)

      assert cypher == "MATCH (n:Person) RETURN sum(n.amount) AS agg0, count(n) AS agg0_card"
    end

    test "first emits WITH n ORDER BY <sort> then head(collect) + companion" do
      sort_q = %Ash.Query{sort: [{:amount, :desc}]}
      a = agg(:first, field: :amount, query: sort_q)
      assert {:ok, cypher, _} = Aggregate.build_statement(base_query(), a, @types)

      assert cypher ==
               "MATCH (n:Person) WITH n ORDER BY n.amount DESC RETURN head(collect(n.amount)) AS agg0, count(n) AS agg0_card"
    end

    test "per-aggregate filter is ANDed onto the base filter (C2)" do
      # base filter scopes tenant; the aggregate's own filter (age == 5) is distinct.
      # Uses AshArcadic.Test.Basic's EXISTING :age integer attribute — Basic's attribute_map
      # is pinned by skeleton_test.exs (== assertion), so do NOT add attributes to Basic.
      # Filter.translate reads attr names structurally, so parsing against Basic while the
      # base_query resource is the test module is fine (translate ignores the query resource).
      q = base_query(["n.t = $param1"], %{"param1" => "org1"})
      agg_query = %Ash.Query{filter: Ash.Filter.parse!(AshArcadic.Test.Basic, age: 5)}
      a = agg(:count, query: agg_query)
      assert {:ok, cypher, params} = Aggregate.build_statement(q, a, @types)
      assert cypher =~ "WHERE n.t = $param1 AND n.age = $param2"
      assert cypher =~ "RETURN count(n) AS agg0"
      assert params["param2"] == 5
    end

    test "a non-aggregatable field fails closed value-free (no cypher built)" do
      assert {:error, {:unaggregatable, :price, :sum}} =
               Aggregate.build_statement(base_query(), agg(:sum, field: :price), @types)
    end

    test "include_nil?: true propagates the value-free rejection (no cypher built)" do
      assert {:error, {:include_nil_unsupported, :list}} =
               Aggregate.build_statement(
                 base_query(),
                 agg(:list, field: :name, include_nil?: true),
                 @types
               )
    end

    test ":first sort by a non-atom (calculation) field fails closed value-free — no struct leak" do
      # order_prefix/1 interpolates each sort field via ident/1 (to_string). A calculation
      # struct sort field (a valid Ash.Sort.t()) would raise Protocol.UndefinedError carrying
      # the struct (opts embed caller literals — the Rule-4 leak guard_field/2 closes for
      # agg.field). guard_sort/1 must reject it value-free BEFORE any to_string.
      calc = %Ash.Query.Calculation{
        name: :c,
        module: SomeMod,
        opts: [secret_literal: "SENSITIVE"],
        type: nil,
        constraints: []
      }

      a = agg(:first, field: :amount, query: %Ash.Query{sort: [{calc, :desc}]})
      assert {:error, :expression_sort} = Aggregate.build_statement(base_query(), a, @types)
    end

    test "an unsupported per-aggregate filter fails closed via translate (not swallowed)" do
      # Distinct from the guard_field path: :count passes guard_field (no field), so
      # execution REACHES translate_agg_filter. A range op on Basic's :binary :secret
      # attr PARSES but Filter.translate rejects it (range-comparable guard) →
      # {:error, %UnsupportedFilter{}}. build_statement must propagate that, NOT build
      # cypher — a swallowed error here would drop the agg filter into an unscoped read.
      require Ash.Query
      rejected = Ash.Query.filter(AshArcadic.Test.Basic, secret > ^<<1, 2, 3>>).filter
      a = agg(:count, query: %Ash.Query{filter: rejected})

      assert {:error, %AshArcadic.Errors.UnsupportedFilter{field: :secret}} =
               Aggregate.build_statement(base_query(), a, @types)
    end
  end

  describe "decode/3 — Ash per-kind defaults + coercion (§6.3)" do
    defp agg_with_default(kind, default, opts \\ []) do
      agg(kind, Keyword.merge([default_value: default], opts))
    end

    test "non-empty sum returns the value (card>0)" do
      rows = [%{"agg0" => 150, "agg0_card" => 3}]
      assert Aggregate.decode(rows, agg_with_default(:sum, nil, field: :amount), @types) == 150
    end

    test "empty sum → struct default (nil), NOT ArcadeDB's 0 (probe G7)" do
      rows = [%{"agg0" => 0, "agg0_card" => 0}]
      assert Aggregate.decode(rows, agg_with_default(:sum, nil, field: :amount), @types) == nil
    end

    test "empty sum with caller default: 0 → 0 (honors struct default_value, C1)" do
      rows = [%{"agg0" => 0, "agg0_card" => 0}]
      assert Aggregate.decode(rows, agg_with_default(:sum, 0, field: :amount), @types) == 0
    end

    test "count → 0 over empty, no companion needed" do
      assert Aggregate.decode([%{"agg0" => 0}], agg_with_default(:count, 0), @types) == 0
    end

    test "exists coerces to a real boolean" do
      assert Aggregate.decode([%{"agg0" => true}], agg_with_default(:exists, nil), @types) == true

      assert Aggregate.decode([%{"agg0" => false}], agg_with_default(:exists, nil), @types) ==
               false
    end

    test "list → [] over empty (no companion)" do
      assert Aggregate.decode(
               [%{"agg0" => []}],
               agg_with_default(:list, [], field: :name),
               @types
             ) == []
    end

    test "value-returning min over :decimal coerces the stored string to a Decimal (S3-22)" do
      # decode/3 tested in ISOLATION here — guard_field/2 blocks min-over-:decimal upstream
      # (range_comparable? is false for :decimal), so this row shape never reaches decode in
      # production. The test pins the coercion contract (Cast.load_value by field type) only.
      rows = [%{"agg0" => "9.50", "agg0_card" => 2}]
      types = Map.put(@types, :price, {Ash.Type.Decimal, []})

      assert %Decimal{} =
               Aggregate.decode(rows, agg_with_default(:min, nil, field: :price), types)
    end

    test "empty min → struct default even though card companion is 0" do
      # non-nil raw agg0 makes this INDEPENDENTLY discriminating: only the card==0 guard
      # (not a coincidental nil) forces the struct default. A mutation reading raw agg0
      # would return 99 here → red.
      rows = [%{"agg0" => 99, "agg0_card" => 0}]
      assert Aggregate.decode(rows, agg_with_default(:min, nil, field: :amount), @types) == nil
    end
  end
end
