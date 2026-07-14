defmodule AshArcadic.Preparations.VectorSearchSparseHybridTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Preparations.VectorSearch

  defmodule HybridDoc do
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
      vector_index(:embedding, dimensions: 3, similarity: :cosine)
      sparse_vector_index(:sparse_embedding, tokens: :tokens, weights: :weights)
    end

    attributes do
      uuid_primary_key :id
      attribute :embedding, {:array, :float}
      attribute :tokens, {:array, :integer}
      attribute :weights, {:array, :float}
      attribute :body, :string
    end

    actions do
      defaults [:read]

      read :sparse_search do
        argument :query_tokens, {:array, :integer}, allow_nil?: false
        argument :query_weights, {:array, :float}, allow_nil?: false
        argument :k, :integer, allow_nil?: false
        prepare {VectorSearch, kind: :sparse, index: :sparse_embedding, group_size: 2}
      end

      read :hybrid_search do
        argument :query_vector, {:array, :float}, allow_nil?: false
        argument :query_tokens, {:array, :integer}, allow_nil?: false
        argument :query_weights, {:array, :float}, allow_nil?: false
        argument :k, :integer, allow_nil?: false

        prepare {VectorSearch,
                 kind: :hybrid, arms: [{:dense, :embedding}, {:sparse, :sparse_embedding}]}
      end

      read :hybrid_fulltext_search do
        argument :query_vector, {:array, :float}, allow_nil?: false
        argument :text_query, :string, allow_nil?: false
        argument :k, :integer, allow_nil?: false

        prepare {VectorSearch,
                 kind: :hybrid, arms: [{:dense, :embedding}, {:fulltext, :body}], fusion: :dbsf}
      end

      read :sparse_bad_index do
        argument :query_tokens, {:array, :integer}, allow_nil?: false
        argument :query_weights, {:array, :float}, allow_nil?: false
        argument :k, :integer, allow_nil?: false
        prepare {VectorSearch, kind: :sparse, index: :nonexistent}
      end
    end
  end

  describe "sparse preparation" do
    test "stashes a sparse vector search with resolved tokens/weights properties" do
      query =
        Ash.Query.for_read(HybridDoc, :sparse_search, %{
          query_tokens: [1, 2, 3],
          query_weights: [0.9, 0.5, 0.2],
          k: 5
        })

      assert query.valid?
      vs = query.context[:vector_search]
      assert vs.kind == :sparse
      assert vs.index == :sparse_embedding
      assert vs.tokens_property == :tokens
      assert vs.weights_property == :weights
      assert vs.query_tokens == [1, 2, 3]
      assert vs.query_weights == [0.9, 0.5, 0.2]
      assert vs.k == 5
      assert vs.allow_global? == false
      # N1: sparse passthrough is group_by/group_size ONLY (never ef_search/max_distance).
      assert vs.opts[:group_size] == 2
      refute Keyword.has_key?(vs.opts, :ef_search)
    end

    test "an unknown sparse index fails closed, value-free" do
      query =
        Ash.Query.for_read(HybridDoc, :sparse_bad_index, %{
          query_tokens: [1],
          query_weights: [0.5],
          k: 3
        })

      refute query.valid?
      assert Enum.any?(query.errors, &(&1.field == :index))
    end

    test "a missing query_tokens arg fails closed" do
      query =
        Ash.Query.for_read(HybridDoc, :sparse_search, %{query_weights: [0.5], k: 3})

      refute query.valid?
    end
  end

  describe "hybrid preparation" do
    test "stashes a hybrid search with two resolved arms (dense + sparse)" do
      query =
        Ash.Query.for_read(HybridDoc, :hybrid_search, %{
          query_vector: [1.0, 0.0, 0.0],
          query_tokens: [1, 2, 3],
          query_weights: [0.9, 0.5, 0.2],
          k: 4
        })

      assert query.valid?
      vs = query.context[:vector_search]
      assert vs.kind == :hybrid
      assert length(vs.arms) == 2
      assert vs.allow_global? == false

      dense = Enum.find(vs.arms, &(&1.kind == :dense))
      sparse = Enum.find(vs.arms, &(&1.kind == :sparse))
      assert dense.property == :embedding
      assert dense.query_vector == [1.0, 0.0, 0.0]
      assert dense.k == 4
      assert sparse.tokens_property == :tokens
      assert sparse.weights_property == :weights
      assert sparse.query_tokens == [1, 2, 3]
      # fusion default rrf; k threaded to the fused output
      assert vs.opts[:fusion] == :rrf
      assert vs.opts[:k] == 4
    end

    test "stashes a hybrid search with a full-text arm (inline property + text_query)" do
      query =
        Ash.Query.for_read(HybridDoc, :hybrid_fulltext_search, %{
          query_vector: [1.0, 0.0, 0.0],
          text_query: "graph",
          k: 3
        })

      assert query.valid?
      vs = query.context[:vector_search]
      assert vs.kind == :hybrid
      ft = Enum.find(vs.arms, &(&1.kind == :fulltext))
      assert ft.property == :body
      assert ft.text_query == "graph"
      assert ft.k == 3
      assert vs.opts[:fusion] == :dbsf
    end

    test "a missing arg for one arm fails closed" do
      query =
        Ash.Query.for_read(HybridDoc, :hybrid_search, %{
          query_vector: [1.0, 0.0, 0.0],
          # query_tokens omitted → the sparse arm cannot resolve
          query_weights: [0.9, 0.5, 0.2],
          k: 4
        })

      refute query.valid?
    end
  end

  describe "init/1" do
    test "hybrid requires an :arms list of at least 2 arms" do
      assert {:error, _} = VectorSearch.init(kind: :hybrid, arms: [{:dense, :embedding}])
      assert {:error, _} = VectorSearch.init(kind: :hybrid)

      assert {:ok, _} =
               VectorSearch.init(kind: :hybrid, arms: [{:dense, :embedding}, {:fulltext, :body}])
    end

    test "sparse requires an :index atom (kind defaults to dense)" do
      assert {:error, _} = VectorSearch.init(kind: :sparse)
      assert {:ok, _} = VectorSearch.init(kind: :sparse, index: :sparse_embedding)
      # dense default preserved
      assert {:ok, _} = VectorSearch.init(index: :embedding)
    end

    test "an unknown kind fails closed" do
      assert {:error, _} = VectorSearch.init(kind: :bogus, index: :embedding)
    end
  end
end
