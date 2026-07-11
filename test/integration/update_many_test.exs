defmodule AshArcadic.Integration.UpdateManyTest do
  @moduledoc false
  use AshArcadic.Test.IntegrationCase

  require Ash.Expr
  alias AshArcadic.Test.CrudPerson

  # CONFIRMED ROUTING (verified against deps/ash at exec): the AshArcadic.DataLayer.update_many/3
  # callback is reached ONLY via `Ash.update_many(inputs, resource, action, opts)` — a list of
  # `{record_or_identifier, input}` tuples with `strategy: :atomic` (or :atomic_batches) and the
  # `:update_many` capability true (deps/ash actions/update/update_many.ex run_batch/use_update_many?
  # → ash.ex:3537). `Ash.bulk_update` does NOT route here — it uses update_query / :stream. Ash groups
  # the changesets by `{atomics, filter}` and calls update_many/3 once per group. A static `%{name: X}`
  # change stays in changeset.attributes with atomics: [] and filter: nil (probed at exec:
  # fully_atomic_changeset keeps a plain literal as an attribute), so all three seeded records share
  # group key {[], nil} → ONE 3-ROW group → update_many/3 fires ONCE, exercising the multi-row `$rows`
  # UNWIND (`n += r.set` across all three rows). The telemetry assertion below proves the callback
  # actually ran (not the update_query fallback, which would emit a different span) — a non-vacuity
  # anchor per the "harness observes the code under test" rule.

  # DETACH DELETE after each test — ArcadeDB has no PK uniqueness, so a per-test re-seed accumulates.
  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CrudPerson) DETACH DELETE n") end)

    for {id, name, age} <- [{"p1", "Ann", 30}, {"p2", "Bo", 40}, {"p3", "Cy", 50}] do
      CrudPerson
      |> Ash.Changeset.for_create(:create, %{id: id, name: name, age: age})
      |> Ash.create!()
    end

    :ok
  end

  test "heterogeneous per-record update: each record its own change, routed through update_many/3" do
    records = Ash.read!(CrudPerson)

    parent = self()
    handler_id = "update-many-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [[:ash_arcadic, :update_many, :stop]],
      fn _event, _measurements, meta, _config ->
        send(parent, {:update_many_span, meta.result})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    inputs = Enum.map(records, fn r -> {r, %{name: r.name <> "!"}} end)

    result =
      Ash.update_many(inputs, CrudPerson, :update, strategy: :atomic, return_records?: true)

    # Non-vacuity: our update_many/3 span fired. Absent the :update_many capability the whole set
    # falls back to per-record update_query (a different span) and this assertion would never arrive.
    assert_receive {:update_many_span, :ok}

    assert result.status == :success
    names = result.records |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["Ann!", "Bo!", "Cy!"]
  end

  test "a record absent from the graph is absent from the data-layer result (matched row still updates)" do
    present = Ash.get!(CrudPerson, "p1")
    ghost = struct(CrudPerson, %{id: "gone", name: "G", age: 1})

    result =
      Ash.update_many(
        [{present, %{name: "Kept"}}, {ghost, %{name: "Nope"}}],
        CrudPerson,
        :update,
        strategy: :atomic,
        return_records?: true,
        return_errors?: true
      )

    # update_many/3 returned ONLY the matched row — the ghost simply did not MATCH in the per-row
    # UNWIND, so it is absent from the records (NOT a data-layer error that aborts the whole batch).
    ids = Enum.map(result.records, & &1.id)
    assert ids == ["p1"]
    refute "gone" in ids
    assert Ash.get!(CrudPerson, "p1").name == "Kept"

    # Ash's ACTION layer (not the data layer) turns the unmatched target into a per-row StaleRecord;
    # the matched row still committed → :partial_success. This proves the callback returned matched-
    # only rows rather than failing the batch on the missing PK (spec D2 bulk semantics).
    assert result.status == :partial_success
    assert result.error_count == 1
  end

  # A group's shared changeset.filter (rep.filter) must scope the UNWIND MATCH, symmetric with
  # update/2 & destroy/2's changeset_where — else a filtered-out row is silently over-updated. No
  # EXISTING fixture/action routes a filtered changeset to update_many/3 through the full stack:
  # OptimisticLock.atomic/3 (deps/ash change/optimistic_lock.ex:33) is the only stack producer of
  # changeset.filter for an atomic update, and no test resource uses it. So this exercises the
  # data-layer callback DIRECTLY with realistically-built changesets (`Ash.Changeset.filter/2`
  # produces the same `%Ash.Filter{}` OptimisticLock does), which is the correct level to prove the
  # filter composition — the callback is the code under test.
  test "changeset.filter scopes the update — a filtered-out row is NOT matched or mutated" do
    p1 = Ash.get!(CrudPerson, "p1")
    p2 = Ash.get!(CrudPerson, "p2")

    # Both changesets set name "Z" and carry the SAME filter (age == 30) — a real update_many group
    # shares one filter (the {atomics, filter} group key). Only p1 (age 30) satisfies it; p2 (age 40)
    # is filtered out.
    make_cs = fn record ->
      record
      |> Ash.Changeset.for_update(:update, %{name: "Z"})
      |> Ash.Changeset.filter(Ash.Expr.expr(age == 30))
    end

    {:ok, records} =
      AshArcadic.DataLayer.update_many(CrudPerson, [make_cs.(p1), make_cs.(p2)], %{
        return_records?: true,
        tenant: nil,
        calculations: []
      })

    # Only p1 matched the filter → only p1 returned + updated.
    assert Enum.map(records, & &1.id) == ["p1"]
    assert Ash.get!(CrudPerson, "p1").name == "Z"

    # MUTATION PROOF: p2 is UNCHANGED. Dropping the changeset_where composition in run_update_many
    # (updating by PK alone) reddens this line — p2's name becomes "Z", a silent over-update.
    assert Ash.get!(CrudPerson, "p2").name == "Bo"
  end
end
