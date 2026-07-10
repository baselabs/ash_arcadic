defmodule AshArcadic.DataLayer.CombinationDispatchTest do
  @moduledoc false
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Query

  # AshArcadic.Test.Basic is a MockClient-backed, NON-multitenant resource: read_conn resolves the conn
  # handle WITHOUT a DB round-trip (Arcadic.connect just builds a %Conn{} struct — Arcadic.Conn.new/3), and
  # combination_unsupported/2 returns BEFORE any Arcadic.query. So every rejection below is DB-free; the
  # happy path (a supported combination that reaches Arcadic.query) is proven live in Task 6, not here.
  @resource AshArcadic.Test.Basic

  defp build(fields),
    do: struct!(Query, Keyword.merge([resource: @resource, label: :Person], fields))

  test "per-branch limit fails closed (native union path)" do
    q = build(combination_of: [{:base, build(limit: 2)}, {:union, build([])}])

    assert {:error, err} = DL.run_query(q, @resource)
    assert Exception.message(err) =~ "per-branch limit/offset"
  end

  test "per-branch offset fails closed" do
    q = build(combination_of: [{:base, build(offset: 3)}, {:union, build([])}])

    assert {:error, err} = DL.run_query(q, @resource)
    assert Exception.message(err) =~ "per-branch limit/offset"
  end

  test "per-branch calculations fail closed" do
    q =
      build(
        combination_of: [{:base, build(calculations: [{:some, :calc}])}, {:intersect, build([])}]
      )

    assert {:error, err} = DL.run_query(q, @resource)
    assert Exception.message(err) =~ "calculations on a combination branch"
  end

  test "expression-calculation sort on an intersect/except combination fails closed (in-memory path)" do
    q =
      build(
        combination_of: [{:base, build([])}, {:intersect, build([])}],
        sort: [{:expr, "n.amount", :asc}]
      )

    assert {:error, err} = DL.run_query(q, @resource)
    assert Exception.message(err) =~ "expression-calculation sort"
  end

  test "a lazy filter expression on an intersect/except combination fails closed (in-memory path)" do
    expression = Ash.Query.filter(@resource, name == "x").filter

    q =
      build(
        combination_of: [{:base, build([])}, {:except, build([])}],
        expression: expression
      )

    assert {:error, err} = DL.run_query(q, @resource)
    assert Exception.message(err) =~ "lazy filter expression"
  end
end
