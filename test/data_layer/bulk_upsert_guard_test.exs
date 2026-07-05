defmodule AshArcadic.DataLayer.BulkUpsertGuardTest do
  use ExUnit.Case, async: true

  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Errors.CreateFailed
  alias AshArcadic.Test.Basic

  # Ash routes a bulk action with `upsert? true` to `bulk_create/3` with
  # `options.upsert? == true` (Ash.DataLayer bulk_create_options; bulk.ex:1351).
  # AshArcadic has no bulk-upsert (native MERGE is single-row); the plan documents
  # it as a non-goal. It must FAIL CLOSED — silently emitting `UNWIND ... CREATE`
  # would create DUPLICATES for what the caller asked to be idempotent (fail-open
  # against the upsert contract).
  #
  # NON-VACUITY: MockClient points at the live server with WRONG credentials, so a
  # stray CREATE also returns {:error, %CreateFailed{}} (auth failure) — the struct
  # match alone is vacuous. We assert the REASON is the guard's static string, which
  # the transport/auth error path (redact_db_error → "ArcadeDB ... error") can never
  # produce. Removing the guard turns this RED.
  test "bulk_create fails closed on an unsupported bulk upsert (never silently CREATEs duplicates)" do
    changeset = %Ash.Changeset{resource: Basic, attributes: %{name: "a"}}

    assert {:error, %CreateFailed{} = error} =
             DL.bulk_create(Basic, [changeset], %{upsert?: true, return_records?: true})

    assert error.reason =~ "bulk upsert"
  end

  # Upsert-specific, not a blanket bulk reject: a non-upsert batch is NOT caught by
  # the guard — it reaches the CREATE path (which fails here only on MockClient's bad
  # auth, a reason WITHOUT "bulk upsert"). Proves the guard keys on `upsert?`.
  test "a non-upsert bulk batch is not caught by the guard (reaches the CREATE path)" do
    changeset = %Ash.Changeset{resource: Basic, attributes: %{name: "a"}}

    assert {:error, %CreateFailed{} = error} =
             DL.bulk_create(Basic, [changeset], %{upsert?: false, return_records?: true})

    refute error.reason =~ "bulk upsert"
  end
end
