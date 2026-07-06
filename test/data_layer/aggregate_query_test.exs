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

  test "run_aggregate_query/3 fails closed value-free for a :context resource with a blank tenant" do
    # DB-free: AshArcadic.Test.ContextDoc is :context strategy. A query with database == nil means
    # set_tenant/3 never fired (blank tenant). read_conn/2's :context branch returns
    # {:error, :tenant_required} BEFORE any conn/network I/O, so do_run_aggregate's own
    # :tenant_required arm surfaces a value-free QueryFailed "tenant required for :context read" —
    # the fail-closed defense-in-depth backstop behind Ash-core's TenantRequired.
    query = %AshArcadic.Query{resource: AshArcadic.Test.ContextDoc, database: nil, tenant: nil}
    agg = struct(Ash.Query.Aggregate, name: :c, kind: :count, field: nil, uniq?: false)

    assert {:error, %AshArcadic.Errors.QueryFailed{} = err} =
             AshArcadic.DataLayer.run_aggregate_query(query, [agg], AshArcadic.Test.ContextDoc)

    # value-free: names only the strategy/operation, never a tenant/database value.
    assert Exception.message(err) =~ "tenant required for :context read"
  end

  test "run_aggregate_query/3 rejects a :first aggregate sorting by a non-stored field (value-free)" do
    # DB-free: Basic is non-multitenant → read_conn passthrough; the sort guard fires before any
    # Arcadic.query. :computed is DECLARED but SKIPPED (`arcade do skip [:computed] end`) → not an
    # ArcadeDB property. A :first sorting by it would emit ORDER BY n.computed against a
    # non-existent property (silent arbitrary first). Must fail closed value-free instead.
    query = AshArcadic.DataLayer.resource_to_query(AshArcadic.Test.Basic, AshArcadic.Test.Domain)

    agg =
      struct(Ash.Query.Aggregate,
        name: :f,
        kind: :first,
        field: :age,
        uniq?: false,
        query: %Ash.Query{sort: [{:computed, :desc}]}
      )

    assert {:error, %AshArcadic.Errors.QueryFailed{} = err} =
             AshArcadic.DataLayer.run_aggregate_query(query, [agg], AshArcadic.Test.Basic)

    assert Exception.message(err) =~ "computed"
    assert Exception.message(err) =~ "not a stored attribute"
  end

  test "run_aggregate_query/3 rejects a value-reading aggregate over a SKIPPED field (value-free)" do
    # DB-free: :computed is DECLARED (:string, so it passes guard_field's range-comparable check)
    # but `arcade do skip [:computed] end` → NOT an ArcadeDB property. min(n.computed) would read a
    # non-existent property → null → the Ash default (silent nil). Must fail closed value-free —
    # the guard fires before build_statement/Arcadic.query. count/exists (presence-only) stay allowed.
    query = AshArcadic.DataLayer.resource_to_query(AshArcadic.Test.Basic, AshArcadic.Test.Domain)
    agg = struct(Ash.Query.Aggregate, name: :m, kind: :min, field: :computed, uniq?: false)

    assert {:error, %AshArcadic.Errors.QueryFailed{} = err} =
             AshArcadic.DataLayer.run_aggregate_query(query, [agg], AshArcadic.Test.Basic)

    assert Exception.message(err) =~ "computed"
    assert Exception.message(err) =~ "not a stored attribute"
  end
end
