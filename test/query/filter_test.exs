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

  describe "filterable-field guard (Slice-6)" do
    test "a value comparison on a SENSITIVE field fails closed value-free (per operator)" do
      # :secret is sensitive (encrypted binary) — plaintext comparison is meaningless.
      assert {:error, %UnsupportedFilter{operator: Ash.Query.Operator.Eq, field: :secret}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, secret == ^<<1, 2, 3>>))

      assert {:error, %UnsupportedFilter{operator: Ash.Query.Operator.NotEq, field: :secret}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, secret != ^<<1, 2, 3>>))

      assert {:error, %UnsupportedFilter{field: :secret}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, secret in [^<<1, 2, 3>>]))

      # range op on the sensitive binary field — rejected (field preserved), value-free.
      {:error, err} = t(Ash.Query.filter(AshArcadic.Test.Basic, secret > ^<<1, 2, 3>>))
      assert %UnsupportedFilter{field: :secret} = err
      refute Exception.message(err) =~ Base.encode64(<<1, 2, 3>>)
    end

    test "a value comparison on a NON-STORED (skip-ped) field fails closed value-free" do
      # :computed is skip-ped → not a stored ArcadeDB property (mirrors the sort guard).
      assert {:error, %UnsupportedFilter{operator: Ash.Query.Operator.Eq, field: :computed}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, computed == "x"))
    end

    test "a string function on a SENSITIVE field fails closed value-free (per function)" do
      # The string funcs route through string_op → binary_op's reject, carrying the FUNCTION module.
      assert {:error, %UnsupportedFilter{operator: Ash.Query.Function.Contains, field: :secret}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, contains(secret, "x")))

      assert {:error,
              %UnsupportedFilter{operator: Ash.Query.Function.StringStartsWith, field: :secret}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, string_starts_with(secret, "x")))

      assert {:error,
              %UnsupportedFilter{operator: Ash.Query.Function.StringEndsWith, field: :secret}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, string_ends_with(secret, "x")))
    end

    test "is_nil / not is_nil on a sensitive field are ALLOWED (presence, reads no value)" do
      assert {:ok, _q, "n.secret IS NULL"} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, is_nil(secret)))

      assert {:ok, _q, "NOT (n.secret IS NULL)"} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, not is_nil(secret)))
    end

    test "is_nil / not is_nil on a NON-STORED (skip-ped) field fails closed value-free" do
      # :computed is skip-ped → no ArcadeDB property, so `n.computed IS NULL` matches EVERY row
      # (ArcadeDB treats a missing property as null) — the SAME silent-wrong-result footgun the
      # value-comparison guard closes. A presence check is meaningful only on a STORED property;
      # is_nil on a stored SENSITIVE field stays allowed (the presence oracle, spec D9, above).
      assert {:error, %UnsupportedFilter{operator: Ash.Query.Operator.IsNil, field: :computed}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, is_nil(computed)))

      assert {:error, %UnsupportedFilter{operator: Ash.Query.Operator.IsNil, field: :computed}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, not is_nil(computed)))
    end

    test "a normal stored non-sensitive field still emits (regression)" do
      assert {:ok, _q, "n.name = $param1"} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, name == "Ann"))

      assert {:ok, _q, "n.age > $param1"} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, age > 18))
    end

    test "nil / non-arcade resource → guard does not reject (cannot check), does not raise" do
      # A resource-less query (the pre-thread changeset_where shape) must not crash.
      f = Ash.Query.filter(AshArcadic.Test.Basic, name == "Ann").filter

      assert {:ok, _q, "n.name = $param1"} =
               Filter.translate(f, %AshArcadic.Query{resource: nil})
    end

    test "a string function with a Ref in a NON-first argument fails closed value-free" do
      # contains(name, <other Ref>) — an attribute-to-attribute in function form. Currently reaches
      # Cast.serialize_value(%Ref{}) and fails LOUD at ArcadeDB; must be a clean UnsupportedFilter.
      # Cover ALL THREE string functions the guard lists (else a dropped module regresses silently).
      assert {:error, %UnsupportedFilter{operator: Ash.Query.Function.Contains, field: :name}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, contains(name, age)))

      assert {:error,
              %UnsupportedFilter{operator: Ash.Query.Function.StringStartsWith, field: :name}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, string_starts_with(name, age)))

      assert {:error,
              %UnsupportedFilter{operator: Ash.Query.Function.StringEndsWith, field: :name}} =
               t(Ash.Query.filter(AshArcadic.Test.Basic, string_ends_with(name, age)))
    end
  end
end
