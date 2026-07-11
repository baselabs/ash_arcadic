defmodule AshArcadic.Integration.UpdateManyTest do
  @moduledoc false
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Test.CrudPerson

  # CONFIRMED ROUTING (verified against deps/ash at exec): the AshArcadic.DataLayer.update_many/3
  # callback is reached ONLY via `Ash.update_many(inputs, resource, action, opts)` — a list of
  # `{record_or_identifier, input}` tuples with `strategy: :atomic` (or :atomic_batches) and the
  # `:update_many` capability true (deps/ash actions/update/update_many.ex run_batch/use_update_many?
  # → ash.ex:3537). `Ash.bulk_update` does NOT route here — it uses update_query / :stream. Ash groups
  # the changesets by `{atomics, filter}` and calls update_many/3 once per group; distinct per-row
  # atomics (each name differs) means one single-row group per record, so the callback fires per row.
  # The telemetry assertion below proves the callback actually ran (not the update_query fallback,
  # which would emit a different span) — a non-vacuity anchor per the "harness observes the code under
  # test" rule.

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
end
