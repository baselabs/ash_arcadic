defmodule AshArcadic.Integration.VectorSearchSparseHybridTest do
  @moduledoc """
  Live isolation proof for SPARSE + HYBRID vector search. Rides Plan 1's tenant-scoping mechanism
  (self-injecting candidate-set); this proves it holds for sparse `sparse_neighbors` AND every fuse
  arm — INCLUDING the full-text arm (which interpolates the shared `filter:` as `@rid IN [<lits>]`).
  The dataset is engineered so the GLOBAL top-k mixes tenants (attacker "b" seeded FIRST, crowding
  the query) — so a scoped read returning only "a" is NON-VACUOUS. Mutation-proven at the tail.
  """
  use AshArcadic.Test.IntegrationCase
  alias AshArcadic.Test.VectorDoc

  @qv [1.0, 0.0, 0.0]
  @qt [1, 2, 3]
  @qw [0.9, 0.5, 0.2]

  setup_all %{admin: admin} do
    sql = fn s -> Arcadic.command!(admin, s, %{}, language: "sql") end
    sql.("CREATE VERTEX TYPE VectorDoc")
    sql.("CREATE PROPERTY VectorDoc.id STRING")
    sql.("CREATE PROPERTY VectorDoc.org STRING")
    sql.("CREATE PROPERTY VectorDoc.name STRING")
    sql.("CREATE PROPERTY VectorDoc.status STRING")
    sql.("CREATE PROPERTY VectorDoc.embedding ARRAY_OF_FLOATS")
    sql.("CREATE PROPERTY VectorDoc.tokens ARRAY_OF_INTEGERS")
    sql.("CREATE PROPERTY VectorDoc.weights ARRAY_OF_FLOATS")
    sql.("CREATE PROPERTY VectorDoc.body STRING")

    # Indexes BEFORE load (sparse retro-index caveat — vector.ex:89). dense idempotent; FT host-side.
    Arcadic.Vector.create_dense_index!(admin, "VectorDoc", "embedding", 3, similarity: :cosine)
    :ok = Arcadic.Vector.create_sparse_index(admin, "VectorDoc", "tokens", "weights")
    :ok = Arcadic.FullText.create_index(admin, "VectorDoc", "body")

    # Attacker tenant "b" FIRST, clustered on every query arm (crowds the global top-k). Tenant "a"
    # spread; a3 is inactive + carries no "graph" body (for the caller-filter + FT tripwires).
    rows = [
      {"b1", "b", "active", "[1.0,0.0,0.0]", "[1,2,3]", "[0.9,0.5,0.2]", "graph database engine"},
      {"b2", "b", "active", "[0.99,0.01,0.0]", "[1,2,3]", "[0.9,0.5,0.25]",
       "graph vector engine"},
      {"a1", "a", "active", "[0.9,0.1,0.0]", "[1,2,3]", "[0.85,0.5,0.2]", "graph search node"},
      {"a2", "a", "active", "[0.5,0.5,0.0]", "[1,2,4]", "[0.6,0.5,0.4]", "graph fraud ring"},
      {"a3", "a", "inactive", "[0.0,0.0,1.0]", "[1,3,5]", "[0.5,0.5,0.5]", "vector index only"}
    ]

    for {id, org, status, emb, tk, w, body} <- rows do
      Arcadic.command!(
        admin,
        "INSERT INTO VectorDoc SET id='#{id}', org='#{org}', name='#{id}', status='#{status}', " <>
          "embedding=#{emb}, tokens=#{tk}, weights=#{w}, body=:body",
        %{"body" => body},
        language: "sql"
      )
    end

    :ok
  end

  defp search(action, args, opts) do
    VectorDoc
    |> Ash.Query.for_read(action, args)
    |> then(fn q -> if opts[:tenant], do: Ash.Query.set_tenant(q, opts[:tenant]), else: q end)
    |> Ash.read(authorize?: false)
  end

  defp orgs(rows), do: rows |> Enum.map(& &1.org) |> Enum.uniq() |> Enum.sort()

  # === Non-vacuity: the GLOBAL top-k is the attacker tenant, so scoping is a real proof ===

  test "crowding: the global sparse top-2 is the attacker tenant 'b'" do
    {:ok, rows} =
      search(:global_sparse_search, %{query_tokens: @qt, query_weights: @qw, k: 2}, [])

    assert orgs(rows) == ["b"]
  end

  test "crowding: the global dense+full-text hybrid mixes tenants (FT-arm non-vacuity, N2)" do
    {:ok, rows} =
      search(:global_hybrid_fulltext_search, %{query_vector: @qv, text_query: "graph", k: 5}, [])

    assert "b" in Enum.map(rows, & &1.org), "the unscoped FT hybrid must surface an attacker row"
  end

  # === Sparse ===

  test "T-sparse-scoped: an :attribute sparse read returns ONLY the tenant's rows + :vector_score" do
    {:ok, rows} =
      search(:sparse_search, %{query_tokens: @qt, query_weights: @qw, k: 5}, tenant: "a")

    assert Enum.all?(rows, &(&1.org == "a")),
           "cross-tenant leak: #{inspect(Enum.map(rows, & &1.org))}"

    assert Enum.all?(rows, &is_number(&1.__metadata__[:vector_score])), "missing :vector_score"
    # sparse rows rank by score, NOT distance
    refute Enum.any?(rows, &is_number(&1.__metadata__[:vector_distance]))
  end

  test "T-sparse-bypass+filter: a :bypass sparse action + caller filter is STILL tenant-scoped" do
    {:ok, rows} =
      search(:bypass_sparse_active, %{query_tokens: @qt, query_weights: @qw, k: 5}, tenant: "a")

    assert Enum.all?(rows, &(&1.org == "a")),
           "leak via :bypass sparse + filter: #{inspect(Enum.map(rows, & &1.org))}"

    assert Enum.all?(rows, &(&1.status == "active")), "caller filter dropped"
    refute "a3" in Enum.map(rows, & &1.name)
  end

  test "T-sparse-global-opt-in: allow_global? sparse spans tenants (the only path to global)" do
    {:ok, rows} =
      search(:global_sparse_search, %{query_tokens: @qt, query_weights: @qw, k: 5}, [])

    assert orgs(rows) == ["a", "b"]
  end

  # === Hybrid ===

  test "T-hybrid-scoped: an :attribute dense+sparse hybrid returns ONLY the tenant's rows" do
    {:ok, rows} =
      search(
        :hybrid_search,
        %{query_vector: @qv, query_tokens: @qt, query_weights: @qw, k: 5},
        tenant: "a"
      )

    assert Enum.all?(rows, &(&1.org == "a")),
           "cross-tenant leak (hybrid): #{inspect(Enum.map(rows, & &1.org))}"

    assert Enum.all?(rows, &is_number(&1.__metadata__[:vector_score])), "hybrid ranks by score"
  end

  test "T-hybrid-fulltext-scoped: the FULL-TEXT arm is scoped by the candidate set (P5 lock)" do
    {:ok, rows} =
      search(:hybrid_fulltext_search, %{query_vector: @qv, text_query: "graph", k: 5},
        tenant: "a"
      )

    assert Enum.all?(rows, &(&1.org == "a")),
           "FT-arm cross-tenant leak: #{inspect(Enum.map(rows, & &1.org))}"

    # "graph" matches b1/b2/a1/a2 globally; scoping must exclude every "b" row.
    refute Enum.any?(rows, &(&1.org == "b"))
  end

  test "T-hybrid-fulltext-bypass: the FT arm is scoped by self-injection alone (the leak class)" do
    # :bypass ⇒ Ash adds NO tenant predicate; only ash_arcadic's self-injecting candidate-set scopes
    # the full-text arm. RED-capable: disabling self-injection leaks the attacker "b" rows through
    # the `@rid IN [...]`-interpolated FT arm.
    {:ok, rows} =
      search(:bypass_hybrid_fulltext_search, %{query_vector: @qv, text_query: "graph", k: 5},
        tenant: "a"
      )

    assert Enum.all?(rows, &(&1.org == "a")),
           "FT-arm leak via :bypass: #{inspect(Enum.map(rows, & &1.org))}"
  end
end
