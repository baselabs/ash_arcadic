defmodule AshArcadic.Preparations.VectorSearchTest do
  use ExUnit.Case, async: true

  defmodule Doc do
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
      vector_index(:embedding, dimensions: 3, similarity: :cosine)
    end

    attributes do
      uuid_primary_key :id
      attribute :embedding, {:array, :float}
    end

    actions do
      defaults [:read]

      read :semantic_search do
        argument :query_vector, {:array, :float}, allow_nil?: false
        argument :k, :integer, allow_nil?: false
        prepare {AshArcadic.Preparations.VectorSearch, index: :embedding, max_distance: 0.5}
      end
    end
  end

  describe "prepare/3 (run via Ash.Query.for_read)" do
    test "stashes the vector search onto the query context" do
      query = Ash.Query.for_read(Doc, :semantic_search, %{query_vector: [1.0, 0.0, 0.0], k: 5})

      assert query.valid?

      vs = query.context[:vector_search]
      assert vs.kind == :dense
      assert vs.index == :embedding
      assert vs.query_vector == [1.0, 0.0, 0.0]
      assert vs.k == 5
      assert vs.allow_global? == false
      assert vs.opts[:max_distance] == 0.5
    end

    test "a vector whose length != declared dimensions fails closed, value-free" do
      query = Ash.Query.for_read(Doc, :semantic_search, %{query_vector: [1.0, 0.0], k: 5})

      refute query.valid?
      [error | _] = query.errors
      assert error.field == :query_vector
      # value-free: the message names the mismatch, never the vector values
      refute to_string(Exception.message(error)) =~ "1.0"
    end

    test "k <= 0 fails closed" do
      query = Ash.Query.for_read(Doc, :semantic_search, %{query_vector: [1.0, 0.0, 0.0], k: 0})
      refute query.valid?
      assert Enum.any?(query.errors, &(&1.field == :k))
    end
  end

  describe "init/1" do
    test "requires an :index atom option" do
      assert {:error, _} = AshArcadic.Preparations.VectorSearch.init([])
      assert {:ok, _} = AshArcadic.Preparations.VectorSearch.init(index: :embedding)
    end
  end

  describe "set_context/3 stash copy" do
    test "copies :vector_search from context onto the AshArcadic.Query" do
      vs = %{
        kind: :dense,
        index: :embedding,
        query_vector: [1.0],
        k: 3,
        allow_global?: false,
        opts: []
      }

      assert {:ok, query} =
               AshArcadic.DataLayer.set_context(Doc, %AshArcadic.Query{}, %{vector_search: vs})

      assert query.vector_search == vs
    end

    test "a non-vector read leaves vector_search nil (no regression)" do
      assert {:ok, query} =
               AshArcadic.DataLayer.set_context(Doc, %AshArcadic.Query{}, %{
                 private: %{tenant: "t1"}
               })

      assert query.vector_search == nil
      assert query.tenant == "t1"
    end
  end
end
