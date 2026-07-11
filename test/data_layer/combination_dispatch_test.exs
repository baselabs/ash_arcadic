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

  # NOTE: per-branch limit/offset is NO LONGER rejected — it is SUPPORTED via the in-memory strategy
  # (combination_in_memory?/1 routes any paged combination there so the branch LIMIT is applied AFTER the
  # per-branch tenant filter). Its positive behavior is proven live in test/integration/combinations_test.exs
  # ("native-family branch with a per-branch limit routes to the in-memory path, tenant-scoped"). The former
  # DB-free "per-branch paging fails closed" rejection tests were removed here because the behavior changed.

  test "per-branch calculations fail closed" do
    q =
      build(
        combination_of: [{:base, build(calculations: [{:some, :calc}])}, {:intersect, build([])}]
      )

    assert {:error, err} = DL.run_query(q, @resource)
    assert Exception.message(err) =~ "calculations on a combination branch"
  end

  test "expression-calculation sort on an in-memory combination fails closed" do
    q =
      build(
        combination_of: [{:base, build([])}, {:intersect, build([])}],
        sort: [{:expr, "n.amount", :asc}]
      )

    assert {:error, err} = DL.run_query(q, @resource)
    assert Exception.message(err) =~ "expression-calculation sort"
  end

  test "a lazy filter expression on an in-memory combination fails closed" do
    expression = Ash.Query.filter(@resource, name == "x").filter

    q =
      build(
        combination_of: [{:base, build([])}, {:except, build([])}],
        expression: expression
      )

    assert {:error, err} = DL.run_query(q, @resource)
    assert Exception.message(err) =~ "lazy filter expression"
  end

  test "an expression-calculation sort on a combination BRANCH fails closed (both paths)" do
    q =
      build(
        combination_of: [
          {:base, build(sort: [{:expr, "n.amount + 1", :asc}])},
          {:union, build([])}
        ]
      )

    assert {:error, err} = DL.run_query(q, @resource)
    assert Exception.message(err) =~ "expression-calculation sort on a combination branch"
  end
end
