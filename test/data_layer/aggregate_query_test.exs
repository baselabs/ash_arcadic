defmodule AshArcadic.DataLayer.AggregateQueryTest do
  @moduledoc """
  DB-free regression for run_aggregate_query/3's fail-closed error contract.

  AshArcadic.Test.Basic is NON-multitenant (no `multitenancy` block → strategy :none),
  so read_conn/2 resolves {:ok, conn} via resolve_conn(conn_for(resource), :read) — a pure
  passthrough (session()==nil, not in_transaction? → {:ok, conn}, transaction.ex:64-68) with
  NO network I/O. So run_one_aggregate reaches build_statement/3 (pure) BEFORE any
  Arcadic.query. An aggregate carrying an unpushable OWN filter makes build_statement return
  {:error, %UnsupportedFilter{}}; the reduce must surface a value-free {:error, %QueryFailed{}}
  — NEVER a FunctionClauseError from an aggregate_reason/1 clause that doesn't cover the struct.
  """
  use ExUnit.Case, async: true

  require Ash.Query

  test "run_aggregate_query/3 returns a value-free QueryFailed (not a crash) when an aggregate's own filter uses an unpushable operator" do
    query = AshArcadic.DataLayer.resource_to_query(AshArcadic.Test.Basic, AshArcadic.Test.Domain)

    # :count passes guard_field (no field), so execution REACHES translate_agg_filter. A range
    # op on Basic's :binary :secret PARSES but Filter.translate rejects it (Task 3 proved this
    # exact path yields {:error, %UnsupportedFilter{field: :secret}}).
    rejected = Ash.Query.filter(AshArcadic.Test.Basic, secret > ^<<1, 2, 3>>).filter

    agg =
      struct(Ash.Query.Aggregate,
        name: :c,
        kind: :count,
        field: nil,
        uniq?: false,
        query: %Ash.Query{filter: rejected}
      )

    assert {:error, %AshArcadic.Errors.QueryFailed{}} =
             AshArcadic.DataLayer.run_aggregate_query(query, [agg], AshArcadic.Test.Basic)
  end
end
