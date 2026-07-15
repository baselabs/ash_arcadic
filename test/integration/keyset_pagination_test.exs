defmodule AshArcadic.Integration.KeysetPaginationTest do
  @moduledoc """
  Slice 11 Workstream 1 (keyset pagination). ash_arcadic advertises `can?(:keyset)` AND implements
  `data_layer_keyset_by_default?/0 → false` — the F1 fix: the bare `can?` flip crashes
  (`data_layer_keyset_by_default?/0` is called unconditionally at read.ex:3082 and is an OPTIONAL
  callback, undefined → UndefinedFunctionError); `→ true` silently drops the cursor (Ash stashes
  keyset_opts and expects the data layer to page itself); `→ false` routes to Ash's fallback
  cursor-filter path — a normal `or/and/comparison/is_nil` filter ash_arcadic already translates.

  Ground truth for every walk is a FULL sorted read (no page) — the keyset walk must reproduce Ash's
  own order exactly (no dups, no gaps, no mis-order). Task 2 covers the integer-sort core; Tasks 3–4
  extend this file (multi-type correctness, fail-closed paths, isolation, count).
  """
  use AshArcadic.Test.IntegrationCase
  require Ash.Query

  alias AshArcadic.Test.KeysetDoc

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:KeysetDoc) DETACH DELETE n") end)
    :ok
  end

  # === Keyset walk helpers (shared across Tasks 2–4). ===

  # The full sorted order Ash produces without paging — the ground truth a correct keyset walk equals.
  defp ground_truth(query, tenant) do
    query |> Ash.read!(tenant: tenant) |> Enum.map(& &1.id)
  end

  # Walk every keyset page (page_size at a time), advancing via the last row's cursor, and return the
  # ordered ids. Terminates on `more?: false` or an empty page.
  defp keyset_walk(query, tenant, page_size) do
    first = Ash.read!(query, tenant: tenant, page: [limit: page_size])
    do_walk(query, tenant, page_size, first, first.results)
  end

  defp do_walk(query, tenant, page_size, %{more?: true, results: [_ | _] = results}, acc) do
    cursor = List.last(results).__metadata__.keyset
    next = Ash.read!(query, tenant: tenant, page: [limit: page_size, after: cursor])
    do_walk(query, tenant, page_size, next, acc ++ next.results)
  end

  defp do_walk(_query, _tenant, _page_size, _page, acc), do: Enum.map(acc, & &1.id)

  defp seed(id, org, attrs) do
    {:ok, d} =
      KeysetDoc
      |> Ash.Changeset.for_create(:create, Map.merge(%{id: id, org_id: org}, attrs), tenant: org)
      |> Ash.create()

    d
  end

  # 10 org-a rows with DUPLICATE scores (10 appears 3×, 20 twice) + one NULL score, so the pk
  # tiebreaker and the nulls arm both matter. Returns nothing; call inside a test.
  defp seed_integer_dataset do
    rows = [
      {"d1", 30},
      {"d2", 10},
      {"d3", 20},
      {"d4", 10},
      {"d5", nil},
      {"d6", 10},
      {"d7", 25},
      {"d8", 20},
      {"d9", 5},
      {"da", 40}
    ]

    for {id, score} <- rows, do: seed(id, "org1", %{score: score})
  end

  # === Task 2: integer-sort core correctness. ===

  test "keyset walk over an integer sort == the full-read order, no dups/gaps (ASC, dup values + pk tiebreaker)" do
    seed_integer_dataset()
    query = KeysetDoc |> Ash.Query.sort(score: :asc)

    truth = ground_truth(query, "org1")
    walked = keyset_walk(query, "org1", 2)

    # The cursor reproduces Ash's own total order exactly — across the duplicate-score boundary
    # (10,10,10 and 20,20 resolve by the pk tiebreaker) and past no page boundary is a row skipped/duped.
    assert walked == truth
    assert walked == Enum.uniq(walked), "duplicate id across pages — cursor over-returned"
    assert length(walked) == 10
  end

  test "keyset walk == full-read order for DESC (operator flips), no dups/gaps" do
    seed_integer_dataset()
    query = KeysetDoc |> Ash.Query.sort(score: :desc)

    truth = ground_truth(query, "org1")
    walked = keyset_walk(query, "org1", 3)

    assert walked == truth
    assert walked == Enum.uniq(walked)
    assert length(walked) == 10
  end

  test "the NULL-score row appears exactly once and in the same slot as the full-read order" do
    seed_integer_dataset()
    query = KeysetDoc |> Ash.Query.sort(score: :asc)

    walked = keyset_walk(query, "org1", 2)

    # d5 (null score) is present exactly once, at whatever slot Ash's nulls arm places it — the walk
    # must agree with the full read (proves the IS-NULL keyset arm is reached, not dropped/duped).
    assert Enum.count(walked, &(&1 == "d5")) == 1
    assert walked == ground_truth(query, "org1")
  end

  test "Ash.stream! (keyset strategy) returns the full set exactly once" do
    seed_integer_dataset()
    query = KeysetDoc |> Ash.Query.sort(score: :asc)

    streamed =
      query
      |> Ash.stream!(tenant: "org1", batch_size: 2)
      |> Enum.map(& &1.id)

    # batch_size 2 forces multiple keyset batches; the stream returns every row once, in order.
    assert streamed == ground_truth(query, "org1")
    assert streamed == Enum.uniq(streamed)
    assert length(streamed) == 10
  end
end
