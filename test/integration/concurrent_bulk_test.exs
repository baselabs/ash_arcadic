defmodule AshArcadic.Integration.ConcurrentBulkTest do
  @moduledoc """
  Slice 11 cross-vendor F1, fixed at the arcadic layer: every write command rides ArcadeDB's
  SERVER-SIDE statement retry (`retries:` body param — re-executes the statement on an
  optimistic-lock `ConcurrentModificationException`; an autocommit statement is all-or-nothing, so
  the retry is idempotency-safe by construction and Ash hooks are NEVER re-fired — the retry lives
  below the data layer, around one HTTP command).

  With `transaction: false` each bulk batch is ONE autocommit `UNWIND` statement (identical
  atomicity to a single-statement session), so concurrent batches CONVERGE even on a default-bucket
  type. RED before the wiring: ~85% of concurrent same-type statements conflict on bucket contention
  → `:partial_success` with rows missing (probed: 16-24 of 80 persisted).

  The DEFAULT `transaction: :batch` path opens a session per batch; its conflicts surface at COMMIT
  where no statement retry applies — that path keeps the documented buckets + check-`.status`
  guidance (usage-rules).
  """
  use AshArcadic.Test.IntegrationCase
  require Ash.Query

  alias AshArcadic.Test.CrudPerson

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CrudPerson) DETACH DELETE n") end)
    :ok
  end

  test "concurrent bulk_create (transaction: false) converges fully on a DEFAULT-bucket type" do
    rows = for i <- 1..80, do: %{id: "p#{i}", name: "N#{i}"}

    result =
      Ash.bulk_create(rows, CrudPerson, :create,
        transaction: false,
        max_concurrency: 8,
        batch_size: 8,
        return_records?: false,
        return_errors?: true,
        stop_on_error?: false
      )

    persisted = CrudPerson |> Ash.read!() |> length()

    # Non-vacuity: without the write-side `retries:` this is `:partial_success` with 16-24 of 80
    # persisted (bucket contention, probed 3/3 runs) — both assertions redden.
    assert result.status == :success,
           "expected :success, got #{inspect(result.status)} (#{result.error_count} errors)"

    assert persisted == 80
  end
end
