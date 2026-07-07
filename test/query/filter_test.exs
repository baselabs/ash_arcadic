defmodule AshArcadic.Query.FilterTest do
  use ExUnit.Case, async: true

  require Ash.Query
  alias AshArcadic.Errors.UnsupportedFilter
  alias AshArcadic.Query
  alias AshArcadic.Query.Filter

  # Build a real filter via Ash (gates on can?/2 — advertised by this task), then
  # translate its %Ash.Filter{} expression.
  defp t(%Ash.Query{} = q),
    do: Filter.translate(q.filter, %Query{resource: AshArcadic.Test.Basic})

  test "equality / inequality bind a $param and emit n.attr = / <>" do
    assert {:ok, query, "n.name = $param1"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, name == "Ann"))

    assert query.params == %{"param1" => "Ann"}

    assert {:ok, _q, "n.name <> $param1"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, name != "Ann"))
  end

  test "comparison operators emit >, <, >=, <=" do
    assert {:ok, _q, "n.age > $param1"} = t(Ash.Query.filter(AshArcadic.Test.Basic, age > 18))
    assert {:ok, _q, "n.age < $param1"} = t(Ash.Query.filter(AshArcadic.Test.Basic, age < 65))
    assert {:ok, _q, "n.age >= $param1"} = t(Ash.Query.filter(AshArcadic.Test.Basic, age >= 18))
    assert {:ok, _q, "n.age <= $param1"} = t(Ash.Query.filter(AshArcadic.Test.Basic, age <= 65))
  end

  test "in binds a list; is_nil emits IS NULL / NOT (… IS NULL)" do
    assert {:ok, query, "n.name IN $param1"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, name in ["a", "b"]))

    assert Enum.sort(query.params["param1"]) == ["a", "b"]
    assert {:ok, _q, "n.name IS NULL"} = t(Ash.Query.filter(AshArcadic.Test.Basic, is_nil(name)))

    assert {:ok, _q, "NOT (n.name IS NULL)"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, not is_nil(name)))
  end

  test "string-match functions emit CONTAINS / STARTS WITH / ENDS WITH with bound params" do
    assert {:ok, query, "n.name CONTAINS $param1"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, contains(name, "nn")))

    assert query.params == %{"param1" => "nn"}

    assert {:ok, _q, "n.name STARTS WITH $param1"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, string_starts_with(name, "An")))

    assert {:ok, _q, "n.name ENDS WITH $param1"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, string_ends_with(name, "nn")))
  end

  test "boolean and/or/not compose parenthesized clauses" do
    assert {:ok, _q, "(n.name = $param1 AND n.age > $param2)"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, name == "Ann" and age > 1))

    assert {:ok, _q, "(n.name = $param1 OR n.age > $param2)"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, name == "Ann" or age > 1))

    assert {:ok, _q, "NOT (n.name = $param1)"} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, not (name == "Ann")))
  end

  test "TRIPWIRE: a range op on a :decimal attr fails LOUD as UnsupportedFilter (D27)" do
    assert {:error,
            %UnsupportedFilter{operator: Ash.Query.Operator.GreaterThan, field: :amount} = err} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, amount > ^Decimal.new("1.00")))

    refute Exception.message(err) =~ "1.00"
  end

  test "TRIPWIRE: a range op on a :binary attr fails LOUD as UnsupportedFilter" do
    assert {:error, %UnsupportedFilter{field: :secret}} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, secret > ^<<1, 2, 3>>))
  end

  test "an attribute-to-attribute comparison is rejected (no bindable value)" do
    assert {:error, %UnsupportedFilter{}} =
             t(Ash.Query.filter(AshArcadic.Test.Basic, name == age))
  end

  # Finding A: an aggregate/calculation Ref in a filter is a COMPUTED value, not a stored ArcadeDB
  # property. Emitting `n.post_count > $p` silently matches NOTHING (a wrong result). The translator
  # must reject it structurally with a value-free %UnsupportedFilter{} naming operator + aggregate.
  test "TRIPWIRE (Finding A): a comparison on an aggregate Ref fails LOUD as UnsupportedFilter" do
    q = AshArcadic.Test.RelAuthor |> Ash.Query.filter(post_count > 1)

    # PROVE the discriminator is really an aggregate struct (not a stored attribute) — else the
    # assertion below would be vacuous (a stored attr would translate to a WHERE fragment, not error).
    assert %Ash.Query.Operator.GreaterThan{
             left: %Ash.Query.Ref{attribute: %Ash.Query.Aggregate{}}
           } =
             q.filter.expression

    assert {:error,
            %UnsupportedFilter{operator: Ash.Query.Operator.GreaterThan, field: :post_count} = err} =
             Filter.translate(q.filter, %Query{resource: AshArcadic.Test.RelAuthor})

    # value-free (Rule 4): names the aggregate + operator, never a row/threshold value.
    refute Exception.message(err) =~ "1"
  end
end
