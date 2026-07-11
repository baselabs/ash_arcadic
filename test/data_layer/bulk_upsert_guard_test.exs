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

  # Upsert-specific, not a blanket bulk reject: a non-upsert batch is NOT routed to the
  # bulk-upsert clause — it reaches the CREATE path (which fails here only on
  # MockClient's bad auth, a reason WITHOUT "bulk upsert"). Proves the clause keys on
  # `upsert?`.
  test "a non-upsert bulk batch is not routed to bulk upsert (reaches the CREATE path)" do
    changeset = %Ash.Changeset{resource: Basic, attributes: %{name: "a"}}

    assert {:error, %CreateFailed{} = error} =
             DL.bulk_create(Basic, [changeset], %{upsert?: false, return_records?: true})

    refute error.reason =~ "bulk upsert"
  end
end
