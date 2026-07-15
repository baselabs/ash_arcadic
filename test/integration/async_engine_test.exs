defmodule AshArcadic.Integration.AsyncEngineTest do
  @moduledoc """
  Slice 11 Workstream 3 (spec §5.3): `:async_engine` is advertised so Ash runs INDEPENDENT
  relationship/aggregate loads concurrently. The probe (scratchpad/probe_async.exs) proved
  arcadic's transport pool is concurrent-READ-safe (200 concurrent tenant-scoped reads, zero
  cross-talk); these integration tests are the end-to-end regression that the read-async wiring
  stays correct + tenant-scoped, and that a transactional action still runs SYNC (the `!in_transaction?`
  gate at async_limiter.ex:32 / process_helpers.ex:71).
  """
  use AshArcadic.Test.IntegrationCase
  require Ash.Query

  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Test.{CrudPerson, RelAuthor, RelPost}

  @admin %{admin: true}

  setup %{admin: admin} do
    on_exit(fn ->
      Arcadic.command!(admin, "MATCH (n:RelAuthor) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:RelPost) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:CrudPerson) DETACH DELETE n")
    end)

    :ok
  end

  defp author(id, org, name) do
    {:ok, a} =
      RelAuthor
      |> Ash.Changeset.for_create(:create, %{id: id, org_id: org, name: name}, tenant: org)
      |> Ash.create(actor: @admin)

    a
  end

  defp post(id, org, title, author_id, views) do
    {:ok, p} =
      RelPost
      |> Ash.Changeset.for_create(
        :create,
        %{id: id, org_id: org, title: title, author_id: author_id, views: views},
        tenant: org
      )
      |> Ash.create(actor: @admin)

    p
  end

  test "async_engine capability is advertised" do
    assert DL.can?(RelAuthor, :async_engine)
  end

  # With :async_engine on, Ash fans the three INDEPENDENT loads (:posts, :post_count, :total_views)
  # into concurrent flows. Non-vacuity: a same-id author + post seeded in org2 must NOT bleed into
  # the org1 result — a concurrent load that dropped the tenant predicate would inflate post_count /
  # total_views or leak org2 posts.
  test "concurrent multi-load (relationship + aggregates) returns correct, tenant-scoped results" do
    a1 = author("a1", "org1", "Ann")
    post("p1", "org1", "Alpha", "a1", 10)
    post("p2", "org1", "Beta", "a1", 20)

    # Same author id + a high-views post in org2 — the cross-talk bait.
    author("a1", "org2", "Bob")
    post("p9", "org2", "Zeta", "a1", 999)

    {:ok, loaded} =
      Ash.load(a1, [:posts, :post_count, :total_views], tenant: "org1", actor: @admin)

    assert loaded.post_count == 2
    assert loaded.total_views == 30
    assert loaded.posts |> Enum.map(& &1.id) |> Enum.sort() == ["p1", "p2"]
    refute "p9" in Enum.map(loaded.posts, & &1.id)
  end

  # The direct pool-concurrency regression (the hazard the probe targeted, now through the full Ash
  # read stack): N processes read concurrently, EACH under a different tenant, and every process must
  # see ONLY its own tenant's rows. This is what Ash's async engine does under the hood (spawn tasks,
  # each a read) — a pool that cross-talked, or a tenant predicate that leaked across processes, reddens.
  test "concurrent reads across distinct tenants never cross-talk (pool isolation under load)" do
    orgs = ~w(org1 org2 org3 org4)
    for org <- orgs, do: author("a_#{org}", org, "Name_#{org}")

    results =
      1..48
      |> Task.async_stream(
        fn i ->
          org = Enum.at(orgs, rem(i, length(orgs)))

          {:ok, rows} =
            RelAuthor
            |> Ash.Query.for_read(:read)
            |> Ash.Query.set_tenant(org)
            |> Ash.read(actor: @admin)

          {org, Enum.map(rows, & &1.name)}
        end,
        max_concurrency: 16,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # Every concurrent read saw exactly its own tenant's single row and nothing from another tenant.
    for {org, names} <- results do
      assert names == ["Name_#{org}"],
             "tenant #{org} read saw #{inspect(names)} — cross-talk across the pool"
    end
  end

  # A transactional action runs SYNC: Ash gates async on `!in_transaction?`, and inside a data-layer
  # transaction ash_arcadic's marker is set — so the exact predicate Ash checks (in_transaction?)
  # is true, disabling async. Non-vacuity: it is FALSE outside the transaction (async permitted there).
  test "a transactional action runs sync — the async-off gate (in_transaction?) is set inside a txn" do
    refute AshArcadic.Transaction.in_transaction?()

    {:ok, observed} =
      DL.transaction(CrudPerson, fn ->
        AshArcadic.Transaction.in_transaction?()
      end)

    assert observed == true
    # And the marker is cleared on exit (async permitted again after the txn).
    refute AshArcadic.Transaction.in_transaction?()
  end
end
