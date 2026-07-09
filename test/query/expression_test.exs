defmodule AshArcadic.Query.ExpressionTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshArcadic.Errors.UnsupportedFilter
  alias AshArcadic.Query
  alias AshArcadic.Query.Expression, as: E

  # Test resource: stored id/first/last/a/b (+ a sensitive `secret` binary, a skipped `computed`,
  # a :decimal `amount`) — exercises the Ref guard. Defined inline (unit, no server).
  defmodule R do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
      label(:R)
      sensitive([:secret])
      skip([:computed])
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :first, :string, public?: true
      attribute :last, :string, public?: true
      attribute :a, :integer, public?: true
      attribute :b, :integer, public?: true
      attribute :amount, :decimal, public?: true
      attribute :secret, :binary, public?: true
      attribute :computed, :string, public?: true
    end
  end

  defp q, do: %Query{resource: R, params: %{}}
  defp ref(name), do: %Ash.Query.Ref{attribute: Info.attribute(R, name)}

  test "plain-attribute Ref → guarded n.<field>" do
    assert {:ok, _q, "n.first"} = E.translate(ref(:first), q())
  end

  test "arithmetic + emits a parenthesized binary op with a bound param for the literal" do
    plus = %Ash.Query.Operator.Basic.Plus{left: ref(:a), right: 5}
    assert {:ok, out, cypher} = E.translate(plus, q())
    assert cypher == "(n.a + $param1)"
    assert out.params == %{"param1" => 5}
  end

  test "division forces float semantics to match Ash (toFloat), not ArcadeDB int truncation" do
    div = %Ash.Query.Operator.Basic.Div{left: ref(:a), right: ref(:b)}
    assert {:ok, _q, "(toFloat(n.a) / (n.b))"} = E.translate(div, q())
  end

  test "concat → +" do
    cat = %Ash.Query.Operator.Basic.Concat{left: ref(:first), right: ref(:last)}
    assert {:ok, _q, "(n.first + n.last)"} = E.translate(cat, q())
  end

  test "comparison → boolean cypher" do
    gt = %Ash.Query.Operator.GreaterThan{left: ref(:a), right: ref(:b)}
    assert {:ok, _q, "(n.a > n.b)"} = E.translate(gt, q())
  end

  test "TRIPWIRE: a sensitive-field Ref fails closed value-free — in EVERY node position" do
    cond = %Ash.Query.Operator.GreaterThan{left: ref(:a), right: ref(:b)}

    for expr <- [
          ref(:secret),
          %Ash.Query.Operator.Basic.Concat{left: ref(:first), right: ref(:secret)},
          %Ash.Query.BooleanExpression{op: :and, left: ref(:secret), right: ref(:a)},
          # comparison operand
          %Ash.Query.Operator.GreaterThan{left: ref(:secret), right: 1},
          # a CASE (if) THEN branch and ELSE branch
          %Ash.Query.Function.If{arguments: [cond, ref(:secret), "x"]},
          %Ash.Query.Function.If{arguments: [cond, "x", ref(:secret)]},
          # a single-argument function argument (lower(secret))
          %Ash.Query.Function.StringDowncase{arguments: [ref(:secret)]},
          # a two-argument string-match function argument (contains(secret, "x"))
          %Ash.Query.Function.Contains{arguments: [ref(:secret), "x"]}
        ] do
      assert {:error, %UnsupportedFilter{}} = E.translate(expr, q())
    end
  end

  test "TRIPWIRE: a non-stored (skip) Ref fails closed in a CASE branch and a function argument" do
    cond = %Ash.Query.Operator.GreaterThan{left: ref(:a), right: ref(:b)}

    for expr <- [
          %Ash.Query.Function.If{arguments: [cond, ref(:computed), "x"]},
          %Ash.Query.Function.StringDowncase{arguments: [ref(:computed)]}
        ] do
      assert {:error, %UnsupportedFilter{}} = E.translate(expr, q())
    end
  end

  test "TRIPWIRE: a nested aggregate Ref inside arithmetic (count_agg + 1) fails closed value-free" do
    # The C6 recursive re-classification: an aggregate Ref embedded in an arithmetic operand still
    # hits the aggregate reject clause on recursion — never emits n.<agg_name> (silent wrong result).
    agg_ref = %Ash.Query.Ref{attribute: %Ash.Query.Aggregate{name: :cnt, kind: :count}}
    expr = %Ash.Query.Operator.Basic.Plus{left: agg_ref, right: 1}
    assert {:error, %UnsupportedFilter{}} = E.translate(expr, q())
  end

  test "TRIPWIRE: a non-stored (skip) Ref and a :decimal/:binary Ref fail closed value-free" do
    assert {:error, %UnsupportedFilter{}} = E.translate(ref(:computed), q())
    assert {:error, %UnsupportedFilter{}} = E.translate(ref(:amount), q())
  end

  test "TRIPWIRE: an aggregate Ref fails closed value-free" do
    agg = %Ash.Query.Ref{attribute: %Ash.Query.Aggregate{name: :cnt, kind: :count}}
    assert {:error, %UnsupportedFilter{}} = E.translate(agg, q())
  end

  test "TRIPWIRE: a relationship-path Ref fails closed value-free (would mistranslate to source node)" do
    # A related-node property (author.first): non-empty relationship_path. The local-attr clause only
    # guards the SOURCE resource, so translating this as n.first silently reads the wrong node.
    rel_ref = %Ash.Query.Ref{relationship_path: [:author], attribute: Info.attribute(R, :first)}
    assert {:error, %UnsupportedFilter{}} = E.translate(rel_ref, q())
  end

  test "params never interpolate the value — literal rides a bound param, not the fragment" do
    plus = %Ash.Query.Operator.Basic.Plus{left: ref(:a), right: 99}
    assert {:ok, out, cypher} = E.translate(plus, q())
    refute cypher =~ "99"
    assert out.params == %{"param1" => 99}
  end

  test "distinct literals in one expression get distinct bound params" do
    # (a * 5) + 3 → two literals must bind to param1 / param2, both present in the cypher.
    expr = %Ash.Query.Operator.Basic.Plus{
      left: %Ash.Query.Operator.Basic.Times{left: ref(:a), right: 5},
      right: 3
    }

    assert {:ok, out, cypher} = E.translate(expr, q())
    assert out.params == %{"param1" => 5, "param2" => 3}
    assert cypher == "((n.a * $param1) + $param2)"
  end

  # --- Task 2: functions, if, calc-ref expansion ---
  defp fn_expr(mod, args), do: struct(mod, arguments: args)

  test "if → CASE WHEN" do
    expr =
      fn_expr(Ash.Query.Function.If, [
        %Ash.Query.Operator.GreaterThan{left: ref(:a), right: ref(:b)},
        "hi",
        "lo"
      ])

    assert {:ok, out, cypher} = E.translate(expr, q())
    assert cypher == "CASE WHEN (n.a > n.b) THEN $param1 ELSE $param2 END"
    assert out.params == %{"param1" => "hi", "param2" => "lo"}
  end

  test "string functions map to ArcadeDB (downcase→lower, length→size, trim→trim, round→round)" do
    assert {:ok, _q, "lower(n.first)"} =
             E.translate(fn_expr(Ash.Query.Function.StringDowncase, [ref(:first)]), q())

    assert {:ok, _q, "size(n.first)"} =
             E.translate(fn_expr(Ash.Query.Function.StringLength, [ref(:first)]), q())

    # D5 names "string_length/length→size" — Ash.Query.Function.Length (list-length) also maps to
    # ArcadeDB size (polymorphic over collections/strings). Keeps advertised = translatable.
    assert {:ok, _q, "size(n.first)"} =
             E.translate(fn_expr(Ash.Query.Function.Length, [ref(:first)]), q())

    assert {:ok, _q, "trim(n.first)"} =
             E.translate(fn_expr(Ash.Query.Function.StringTrim, [ref(:first)]), q())

    assert {:ok, _q, "round(n.a)"} =
             E.translate(fn_expr(Ash.Query.Function.Round, [ref(:a)]), q())
  end

  test "is_nil in a value expression → IS NULL" do
    assert {:ok, _q, "(n.first IS NULL)"} =
             E.translate(fn_expr(Ash.Query.Function.IsNil, [ref(:first)]), q())
  end

  test "contains → CONTAINS (value context)" do
    expr = fn_expr(Ash.Query.Function.Contains, [ref(:first), "Ad"])
    assert {:ok, out, cypher} = E.translate(expr, q())
    assert cypher == "(n.first CONTAINS $param1)"
    assert out.params == %{"param1" => "Ad"}
  end

  test "an un-mapped function fails closed value-free (naming the function)" do
    ago = fn_expr(Ash.Query.Function.Ago, [1, :day])
    assert {:error, %UnsupportedFilter{operator: Ash.Query.Function.Ago}} = E.translate(ago, q())
  end

  # Ash wraps EVERY expression-calculation body (and an explicit type/3 cast) in a Type coercion to
  # the declared type — Ash.Resource.Calculation.expression/3 hands the calc-Ref clause a Type-topped
  # tree. Unwrap and translate the inner (ArcadeDB is dynamically typed; the one type-sensitive op,
  # Div→toFloat, is handled at its own clause). Without this, filter-on-expression-calc rejects.
  test "type(expr, T, constraints) unwraps to its inner expression (drops the cast)" do
    concat = %Ash.Query.Operator.Basic.Concat{left: ref(:first), right: ref(:last)}
    typed = fn_expr(Ash.Query.Function.Type, [concat, Ash.Type.String, []])
    assert {:ok, _q, "(n.first + n.last)"} = E.translate(typed, q())
  end

  test "TRIPWIRE: a Type cast over a sensitive Ref still fails closed value-free (inner guard re-applies)" do
    typed = fn_expr(Ash.Query.Function.Type, [ref(:secret), Ash.Type.String, []])
    assert {:error, %UnsupportedFilter{}} = E.translate(typed, q())
  end
end
