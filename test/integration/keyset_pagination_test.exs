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
  require Ash.Expr

  alias Ash.Query.Combination
  alias AshArcadic.Multitenancy
  alias AshArcadic.Test.{KeysetCtxDoc, KeysetDoc}

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:KeysetDoc) DETACH DELETE n") end)
    :ok
  end

  # Provision two randomized :context tenant DBs for KeysetCtxDoc and drop them on exit (mirrors the
  # relationship_test pattern). The default encoder maps a bare tenant string to `t_<tenant>`.
  defp provision_context(admin, resource) do
    t1 = "korg1_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    t2 = "korg2_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    dbs = Enum.uniq(for org <- [t1, t2], do: Multitenancy.database_name(resource, org))
    for db <- dbs, do: Arcadic.Server.create_database!(admin, db)
    on_exit(fn -> for db <- dbs, do: Arcadic.Server.drop_database(admin, db) end)
    {t1, t2}
  end

  defp ctx_seed(id, tenant, score) do
    {:ok, d} =
      KeysetCtxDoc
      |> Ash.Changeset.for_create(:create, %{id: id, score: score}, tenant: tenant)
      |> Ash.create()

    d
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

  test "keyset before: (backward) pagination returns the preceding page (operator flips to <)" do
    seed_integer_dataset()
    query = KeysetDoc |> Ash.Query.sort(score: :asc)

    p1 = Ash.read!(query, tenant: "org1", page: [limit: 3])

    p2 =
      Ash.read!(query,
        tenant: "org1",
        page: [limit: 3, after: List.last(p1.results).__metadata__.keyset]
      )

    # before: the FIRST row of page 2 walks BACKWARD to exactly page 1's three rows (the cursor
    # operator flips to <). Non-vacuity: p1 is the ground-truth first three (proves it's not an
    # accidental full read).
    before_page =
      Ash.read!(query,
        tenant: "org1",
        page: [limit: 3, before: List.first(p2.results).__metadata__.keyset]
      )

    assert Enum.map(before_page.results, & &1.id) == Enum.map(p1.results, & &1.id)
    assert Enum.map(p1.results, & &1.id) == Enum.take(ground_truth(query, "org1"), 3)
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

  # === Task 3: per-type correctness (F4). Each admitted stored sortable type — the keyset walk
  # reproduces Ash's full-read order across DUPLICATE values (pk tiebreaker). integer is Task 2;
  # utc_datetime rides the T3a temporal-comparison fix (datetime() param wrapper). ===

  test "STRING sort: keyset walk == full-read order (collation, duplicate titles)" do
    for {id, t} <- [
          {"s1", "Ann"},
          {"s2", "Bo"},
          {"s3", "Ann"},
          {"s4", "Cy"},
          {"s5", "Bo"},
          {"s6", "Ann"}
        ],
        do: seed(id, "org1", %{title: t})

    query = KeysetDoc |> Ash.Query.sort(title: :asc)
    walked = keyset_walk(query, "org1", 2)
    assert walked == ground_truth(query, "org1")
    assert length(walked) == 6
  end

  test "FLOAT sort: keyset walk == full-read order (duplicate + negative ranks)" do
    for {id, r} <- [
          {"f1", 1.5},
          {"f2", 0.5},
          {"f3", 1.5},
          {"f4", 2.25},
          {"f5", 0.5},
          {"f6", -3.0}
        ],
        do: seed(id, "org1", %{rank: r})

    query = KeysetDoc |> Ash.Query.sort(rank: :asc)
    walked = keyset_walk(query, "org1", 2)
    assert walked == ground_truth(query, "org1")
    assert length(walked) == 6
  end

  test "BOOLEAN sort: keyset walk == full-read order (many true/false + pk tiebreaker)" do
    for {id, a} <- [
          {"b1", true},
          {"b2", false},
          {"b3", true},
          {"b4", false},
          {"b5", true},
          {"b6", false}
        ],
        do: seed(id, "org1", %{active: a})

    query = KeysetDoc |> Ash.Query.sort(active: :asc)
    walked = keyset_walk(query, "org1", 2)
    assert walked == ground_truth(query, "org1")
    assert length(walked) == 6
  end

  test "UTC_DATETIME sort: keyset walk == full-read order (T3a temporal fix; duplicate timestamps)" do
    for {id, ts} <- [
          {"t1", ~U[2024-01-02 03:04:05Z]},
          {"t2", ~U[2023-12-31 23:59:59Z]},
          {"t3", ~U[2024-01-02 03:04:05Z]},
          {"t4", ~U[2024-06-15 12:00:00Z]},
          {"t5", ~U[2023-12-31 23:59:59Z]}
        ],
        do: seed(id, "org1", %{created: ts})

    query = KeysetDoc |> Ash.Query.sort(created: :asc)
    walked = keyset_walk(query, "org1", 2)
    assert walked == ground_truth(query, "org1")

    # Non-vacuity: the FULL 5-row walk. Pre-T3a-fix the datetime cursor comparison returned [] and the
    # walk silently truncated to 2 — this length assertion is the tripwire for that silent-skip class.
    assert length(walked) == 5
  end

  test "USEC_DATETIME sort: keyset walk == full-read order (storage :utc_datetime_usec — F-1)" do
    for {id, ts} <- [
          {"u1", ~U[2024-01-02 03:04:05.123456Z]},
          {"u2", ~U[2023-12-31 23:59:59.000001Z]},
          {"u3", ~U[2024-01-02 03:04:05.123456Z]},
          {"u4", ~U[2024-06-15 12:00:00.999999Z]},
          {"u5", ~U[2023-12-31 23:59:59.000001Z]}
        ],
        do: seed(id, "org1", %{created_usec: ts})

    query = KeysetDoc |> Ash.Query.sort(created_usec: :asc)
    walked = keyset_walk(query, "org1", 2)
    assert walked == ground_truth(query, "org1")
    # Tripwire for the F-1 usec silent-mispage: without the :utc_datetime_usec wrapper the cursor
    # comparison returns [] and the walk truncates to 2.
    assert length(walked) == 5
  end

  # === Task 3: fail-closed paths (F3) — TWO mechanisms, TWO error types (a single "S6 rejects all
  # three" test would be vacuous for binary/decimal, which are stopped EARLIER at the sort gate). ===

  test "fail-closed (sort gate): a keyset over a :binary sort field is rejected UnsortableField" do
    seed("x", "org1", %{score: 1})

    assert {:error, error} =
             KeysetDoc |> Ash.Query.sort(blob: :asc) |> Ash.read(tenant: "org1", page: [limit: 2])

    assert Enum.any?(
             List.wrap(error) ++ List.wrap(Map.get(error, :errors)),
             &match?(%Ash.Error.Query.UnsortableField{field: :blob}, &1)
           )
  end

  test "fail-closed (sort gate): a keyset over a :decimal sort field is rejected UnsortableField" do
    seed("x", "org1", %{score: 1})

    assert {:error, error} =
             KeysetDoc
             |> Ash.Query.sort(amount: :asc)
             |> Ash.read(tenant: "org1", page: [limit: 2])

    assert Enum.any?(
             List.wrap(error) ++ List.wrap(Map.get(error, :errors)),
             &match?(%Ash.Error.Query.UnsortableField{field: :amount}, &1)
           )
  end

  test "fail-closed (filter gate): a keyset over a NON-STORED calc sort fails value-free on the cursor page (F5)" do
    for {id, s} <- [{"x", 3}, {"y", 1}, {"z", 2}, {"w", 1}], do: seed(id, "org1", %{score: s})

    query = KeysetDoc |> Ash.Query.sort(bumped_score: :asc)

    # Page 1 (no cursor) succeeds; the CURSOR page builds a keyset filter over the non-stored calc Ref
    # (:__calc__0), which the S6 filter guard rejects value-free (UnsupportedFilter) — a LOUD fail, not
    # a silent mis-page. (bumped_score = score + 1 over the STORED score expands to a translatable
    # expression on the first page, but the cursor's IS NULL / comparison arm references the calc Ref.)
    p1 = Ash.read!(query, tenant: "org1", page: [limit: 1])
    cursor = List.last(p1.results).__metadata__.keyset

    assert {:error, error} = Ash.read(query, tenant: "org1", page: [limit: 1, after: cursor])

    assert Enum.any?(
             List.wrap(error) ++ List.wrap(Map.get(error, :errors)),
             &match?(%AshArcadic.Errors.UnsupportedFilter{}, &1)
           )
  end

  # === Task 3 / F5: keyset over a COMBINATION query is SUPPORTED — the cursor lands in the outer
  # filter of the combination path and pages correctly (defined behavior, not a silent skip). ===

  test "keyset over a COMBINATION query pages correctly (cursor in the outer filter)" do
    for {id, s} <- [{"x", 3}, {"y", 1}, {"z", 2}], do: seed(id, "org1", %{score: s})

    combo =
      KeysetDoc
      |> Ash.Query.for_read(:read)
      |> Ash.Query.combination_of([
        Combination.base(filter: Ash.Expr.expr(score == 1)),
        Combination.union(filter: Ash.Expr.expr(score == 2))
      ])
      |> Ash.Query.sort(score: :asc)

    # base(score==1)=y, union(score==2)=z → sorted keyset walk = [y, z], each once, no gap.
    walked = keyset_walk(combo, "org1", 1)
    assert walked == ground_truth(combo, "org1")
    assert walked == ["y", "z"]
  end

  # === Task 4: cross-tenant isolation across the FULL keyset walk, BOTH strategies (R2). The cursor
  # is a filter value; the tenant predicate must AND independently so no page ever leaks another
  # tenant's rows. Attacker rows seeded FIRST (feedback_adversarial_test_fixture_ordering_defeats_
  # nonvacuity): a scope-then-limit bug (unscoped LIMIT filling from the first-seeded tenant) surfaces. ===

  test "isolation :attribute: a keyset walk under one tenant leaks NO other-tenant row across any page" do
    # Attacker (org2) seeded FIRST; its scores INTERLEAVE org1's (5,15,25,35 vs 10,20,30,40), so an
    # unscoped cursor walk would splice z-rows between the a-rows.
    for {id, s} <- [{"z1", 5}, {"z2", 15}, {"z3", 25}, {"z4", 35}],
        do: seed(id, "org2", %{score: s})

    for {id, s} <- [{"a1", 10}, {"a2", 20}, {"a3", 30}, {"a4", 40}],
        do: seed(id, "org1", %{score: s})

    query = KeysetDoc |> Ash.Query.sort(score: :asc)
    # page size 1 exercises the cursor at EVERY boundary (max chance for a leak).
    walked = keyset_walk(query, "org1", 1)

    assert walked == ["a1", "a2", "a3", "a4"]
    refute Enum.any?(walked, &String.starts_with?(&1, "z")), "cursor walk leaked an org2 row"

    # MUTATION-PROOF: KeysetDoc's `multitenancy attribute :org_id` injects `org_id == "org1"` and ANDs
    # with the cursor filter; strip that block and the interleaved z-rows would appear across the pages.
  end

  test "isolation :context: a keyset walk resolves the tenant DB only; base-DB + other-tenant rows unreachable",
       %{admin: admin, database: base_db} do
    {t1, t2} = provision_context(admin, KeysetCtxDoc)

    # Attacker tenant (t2) + the BASE integration DB seeded FIRST with same-id rows.
    for {id, s} <- [{"a1", 99}, {"a2", 99}], do: ctx_seed(id, t2, s)

    base_conn = Arcadic.with_database(admin, base_db)
    Arcadic.command!(base_conn, "CREATE (n:KeysetCtxDoc {id: 'a1', score: 1})")

    for {id, s} <- [{"a1", 10}, {"a2", 20}, {"a3", 30}], do: ctx_seed(id, t1, s)

    query = KeysetCtxDoc |> Ash.Query.sort(score: :asc)
    walked = keyset_walk(query, t1, 1)

    # Only t1's three rows, in order — never t2's (separate DB) nor the base-DB 'a1'. MUTATION-PROOF:
    # strip `strategy :context` and the walk would fall to the base DB (reaching base 'a1' score 1).
    assert walked == ["a1", "a2", "a3"]
    # And each row is t1's, not the base row: t1's a1 has score 10, base's has score 1.
    {:ok, [%{score: 10}]} =
      KeysetCtxDoc |> Ash.Query.filter(id == "a1") |> Ash.read(tenant: t1)
  end

  # === Task 4: page:[count:true] via run_aggregate_statement — the total is tenant-scoped. ===

  test "page:[count:true] returns the correct tenant-scoped total (not the cross-tenant total)" do
    for {id, s} <- [{"a1", 10}, {"a2", 20}, {"a3", 30}], do: seed(id, "org1", %{score: s})

    for {id, s} <- [{"z1", 5}, {"z2", 15}, {"z3", 25}, {"z4", 35}, {"z5", 45}],
        do: seed(id, "org2", %{score: s})

    page =
      KeysetDoc
      |> Ash.Query.sort(score: :asc)
      |> Ash.read!(tenant: "org1", page: [limit: 2, count: true])

    # count is org1's 3 (NOT the 8 rows across both tenants); the first page carries 2 of them.
    assert page.count == 3
    assert length(page.results) == 2
  end
end
