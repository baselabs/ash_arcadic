defmodule AshArcadic.Integration.VectorSearchTest do
  @moduledoc """
  Live isolation proof for dense vector search. The dataset is engineered so the GLOBAL top-k is
  100% the attacker tenant ("b", seeded FIRST) — so a scoped read returning only "a" rows is
  non-vacuous (an unscoped/leaky search would visibly return "b"). Proves the :attribute
  self-injection scopes even a :bypass action carrying a caller filter (the leak class).
  """
  use AshArcadic.Test.IntegrationCase
  alias AshArcadic.Test.VectorDoc

  @qv [1.0, 0.0, 0.0]

  setup_all %{admin: admin} do
    sql = fn s -> Arcadic.command!(admin, s, %{}, language: "sql") end
    sql.("CREATE VERTEX TYPE VectorDoc")
    sql.("CREATE PROPERTY VectorDoc.id STRING")
    sql.("CREATE PROPERTY VectorDoc.org STRING")
    sql.("CREATE PROPERTY VectorDoc.name STRING")
    sql.("CREATE PROPERTY VectorDoc.status STRING")
    sql.("CREATE PROPERTY VectorDoc.embedding ARRAY_OF_FLOATS")

    # Attacker tenant "b" FIRST, clustered on the query vector (crowds the global top-k); tenant "a"
    # spread far. a3 is inactive (for the caller-filter tripwire).
    rows = [
      {"b1", "b", "active", "[1.0,0.0,0.0]"},
      {"b2", "b", "active", "[0.99,0.01,0.0]"},
      {"a1", "a", "active", "[0.9,0.1,0.0]"},
      {"a2", "a", "active", "[0.0,1.0,0.0]"},
      {"a3", "a", "inactive", "[0.0,0.0,1.0]"}
    ]

    for {id, org, status, emb} <- rows do
      sql.(
        "INSERT INTO VectorDoc SET id='#{id}', org='#{org}', name='#{id}', status='#{status}', embedding=#{emb}"
      )
    end

    Arcadic.Vector.create_dense_index!(admin, "VectorDoc", "embedding", 3, similarity: :cosine)
    :ok
  end

  defp search(action, args, opts) do
    VectorDoc
    |> Ash.Query.for_read(action, args)
    |> then(fn q -> if opts[:tenant], do: Ash.Query.set_tenant(q, opts[:tenant]), else: q end)
    |> Ash.read(authorize?: false)
  end

  test "crowding check: the global top-2 is the attacker tenant 'b' (makes scoping non-vacuous)" do
    {:ok, rows} = search(:global_semantic_search, %{query_vector: @qv, k: 2}, [])
    assert Enum.map(rows, & &1.org) |> Enum.uniq() == ["b"]
  end

  test "T-a :attribute scoped returns ONLY the tenant's rows + distance metadata" do
    {:ok, rows} = search(:semantic_search, %{query_vector: @qv, k: 3}, tenant: "a")

    assert Enum.all?(rows, &(&1.org == "a")),
           "cross-tenant leak: #{inspect(Enum.map(rows, & &1.org))}"

    assert rows |> Enum.map(& &1.name) |> Enum.sort() == ["a1", "a2", "a3"]
    assert Enum.all?(rows, &is_number(&1.__metadata__[:vector_distance]))
    # closest-first: a1 (nearest to [1,0,0]) leads
    assert hd(rows).name == "a1"
  end

  test "T-b :bypass action + caller filter is STILL tenant-scoped (self-injection, the leak class)" do
    {:ok, rows} = search(:bypass_search_active, %{query_vector: @qv, k: 3}, tenant: "a")

    assert Enum.all?(rows, &(&1.org == "a")),
           "leak via :bypass+filter: #{inspect(Enum.map(rows, & &1.org))}"

    assert Enum.all?(rows, &(&1.status == "active")), "caller filter dropped"
    # a3 is inactive → excluded by the filter, proving the filter composed with the scope
    refute "a3" in Enum.map(rows, & &1.name)
  end

  test "T-d global opt-in runs a cross-tenant kNN (spans tenants, the intended global behavior)" do
    {:ok, rows} = search(:global_semantic_search, %{query_vector: @qv, k: 5}, [])
    assert rows |> Enum.map(& &1.org) |> Enum.uniq() |> Enum.sort() == ["a", "b"]
  end

  test "read span carries a value-free vector_search? tag" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ash_arcadic, :read, :stop]])
    {:ok, _} = search(:semantic_search, %{query_vector: @qv, k: 2}, tenant: "a")

    assert_receive {[:ash_arcadic, :read, :stop], ^ref, _measure, meta}
    assert meta.vector_search? == true
    refute Map.has_key?(meta, :query_vector)
  end
end
