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
    for expr <- [
          ref(:secret),
          %Ash.Query.Operator.Basic.Concat{left: ref(:first), right: ref(:secret)},
          %Ash.Query.BooleanExpression{op: :and, left: ref(:secret), right: ref(:a)}
        ] do
      assert {:error, %UnsupportedFilter{}} = E.translate(expr, q())
    end
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
end
