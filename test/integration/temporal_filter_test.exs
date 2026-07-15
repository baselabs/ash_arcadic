defmodule AshArcadic.Integration.TemporalFilterTest do
  @moduledoc """
  Slice 11 (Task 3, user-directed): temporal range/eq/in comparisons must work, not silently return
  wrong results. ArcadeDB auto-coerces stored ISO8601 datetime/time strings to native temporal types,
  so `prop OP $stringparam` matched nothing (silent []). The fix wraps the bound param in the Cypher
  temporal constructor for the coerced classes (`datetime()` for utc/naive datetime, `localtime()` for
  time); `:date` is NOT coerced (kept a string) so it compares correctly unwrapped. Every assertion
  here is RED before the fix for the coerced classes (proves the wrapper is load-bearing).
  """
  use AshArcadic.Test.IntegrationCase
  require Ash.Query

  alias AshArcadic.Test.TemporalDoc

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:TemporalDoc) DETACH DELETE n") end)
    :ok
  end

  defp seed(id, attrs) do
    {:ok, _} =
      TemporalDoc
      |> Ash.Changeset.for_create(:create, Map.merge(%{id: id, org_id: "org1"}, attrs),
        tenant: "org1"
      )
      |> Ash.create()
  end

  defp ids(query),
    do: query |> Ash.Query.set_tenant("org1") |> Ash.read!() |> Enum.map(& &1.id) |> Enum.sort()

  test "utc_datetime range + eq + in comparisons return the correct rows (datetime() wrapper)" do
    seed("a", %{at: ~U[2024-01-02 03:04:05Z]})
    seed("b", %{at: ~U[2023-12-31 23:59:59Z]})
    seed("c", %{at: ~U[2024-06-15 12:00:00Z]})

    # > boundary excludes the equal row (b); includes the later rows (a, c). RED pre-fix ([]).
    assert ids(Ash.Query.filter(TemporalDoc, at > ^~U[2023-12-31 23:59:59Z])) == ["a", "c"]
    assert ids(Ash.Query.filter(TemporalDoc, at < ^~U[2024-06-15 12:00:00Z])) == ["a", "b"]
    assert ids(Ash.Query.filter(TemporalDoc, at >= ^~U[2023-12-31 23:59:59Z])) == ["a", "b", "c"]
    assert ids(Ash.Query.filter(TemporalDoc, at == ^~U[2024-06-15 12:00:00Z])) == ["c"]

    assert ids(
             Ash.Query.filter(
               TemporalDoc,
               at in [^~U[2023-12-31 23:59:59Z], ^~U[2024-06-15 12:00:00Z]]
             )
           ) ==
             ["b", "c"]
  end

  test "naive_datetime range comparison returns the correct rows (datetime() wrapper)" do
    seed("a", %{naive_at: ~N[2024-01-02 03:04:05]})
    seed("b", %{naive_at: ~N[2023-12-31 23:59:59]})
    seed("c", %{naive_at: ~N[2024-06-15 12:00:00]})

    assert ids(Ash.Query.filter(TemporalDoc, naive_at > ^~N[2023-12-31 23:59:59])) == ["a", "c"]
    assert ids(Ash.Query.filter(TemporalDoc, naive_at == ^~N[2024-01-02 03:04:05])) == ["a"]
  end

  test "time range comparison returns the correct rows (localtime() wrapper)" do
    seed("a", %{at_time: ~T[03:04:05]})
    seed("b", %{at_time: ~T[23:59:59]})
    seed("c", %{at_time: ~T[12:00:00]})

    assert ids(Ash.Query.filter(TemporalDoc, at_time > ^~T[12:00:00])) == ["b"]
    assert ids(Ash.Query.filter(TemporalDoc, at_time < ^~T[12:00:00])) == ["a"]
  end

  test "date range comparison works unwrapped (ArcadeDB keeps date-only strings as strings)" do
    seed("a", %{on_date: ~D[2024-01-02]})
    seed("b", %{on_date: ~D[2023-12-31]})
    seed("c", %{on_date: ~D[2024-06-15]})

    assert ids(Ash.Query.filter(TemporalDoc, on_date > ^~D[2023-12-31])) == ["a", "c"]
    assert ids(Ash.Query.filter(TemporalDoc, on_date == ^~D[2024-06-15])) == ["c"]
  end
end
