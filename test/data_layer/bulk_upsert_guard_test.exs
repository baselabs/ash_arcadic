defmodule AshArcadic.DataLayer.BulkUpsertGuardTest do
  use ExUnit.Case, async: true

  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Errors.CreateFailed
  alias AshArcadic.Test.Basic

  # Multi-row bulk upsert is SUPPORTED (Slice 9 Plan 2): Ash routes a bulk action
  # with `upsert? true` to `bulk_create/3` with `options.upsert? == true`, and the
  # data layer emits one `UNWIND ... MERGE` statement (end-to-end coverage lives in
  # test/integration/bulk_upsert_test.exs). This file unit-tests the fail-closed
  # guards on that path WITHOUT a live server.
  #
  # NON-VACUITY: MockClient points at the live server with WRONG credentials, so a
  # stray write also returns {:error, %CreateFailed{}} (auth failure) — the struct
  # match alone is vacuous. Each test asserts the guard's static REASON string, which
  # the transport/auth error path (redact_db_error → "ArcadeDB ... error") can never
  # produce. Removing the guard turns the assertion RED.

  # `upsert_keys: []` yields an empty identity (Basic is non-multitenant, so
  # upsert_identity_keys appends no discriminator). An empty MERGE identity would emit
  # `MERGE (n:Person {})`, matching ANY node — a catastrophic ON MATCH clobber. The
  # guard rejects BEFORE any DB touch (no MockClient auth error can occur), so the
  # reason is uniquely the guard's; removing it lets the MERGE reach MockClient and the
  # reason becomes the auth error (no "non-empty identity") → RED.
  test "bulk upsert fails closed on an empty identity (never emits an unbounded MERGE)" do
    changeset = %Ash.Changeset{resource: Basic, attributes: %{name: "a"}}

    assert {:error, %CreateFailed{} = error} =
             DL.bulk_create(Basic, [changeset], %{
               upsert?: true,
               upsert_keys: [],
               return_records?: true
             })

    assert error.reason =~ "non-empty identity"
  end

  # The `:bulk_create` span tags `bulk_upsert?` per the `upsert?` route — the sole
  # coverage of that telemetry key. Non-vacuous by construction: it asserts the tag is
  # `true` for an upsert batch and `false` for a non-upsert one, so a mislabeled/constant
  # tag reddens. The stop span fires regardless of result (both calls fail at MockClient's
  # bad auth), so no DB write is needed; the handler filters on `resource == Basic` (only
  # this test bulk-creates Basic) to isolate from any concurrent async span.
  test "the :bulk_create span tags bulk_upsert? by the upsert? route (true vs false)" do
    test_pid = self()
    handler_id = {__MODULE__, :bulk_upsert_route, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:ash_arcadic, :bulk_create, :stop],
      fn _event, _measure, meta, pid ->
        if meta.resource == Basic, do: send(pid, {:bulk_upsert_tag, meta.bulk_upsert?})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    changeset = %Ash.Changeset{resource: Basic, attributes: %{name: "a"}}

    # Non-upsert route (catch-all CREATE clause) → bulk_upsert? false.
    DL.bulk_create(Basic, [changeset], %{upsert?: false, return_records?: true})
    assert_received {:bulk_upsert_tag, false}

    # Upsert route (run_bulk_upsert; :id is a non-empty identity) → bulk_upsert? true.
    DL.bulk_create(Basic, [changeset], %{upsert?: true, upsert_keys: [:id], return_records?: true})

    assert_received {:bulk_upsert_tag, true}
  end
end
