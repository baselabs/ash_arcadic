defmodule AshArcadic.Test.VectorContextDoc do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:VectorContextDoc)
    vector_index(:embedding, dimensions: 3, similarity: :cosine)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :embedding, {:array, :float}, public?: true
  end

  multitenancy do
    strategy :context
  end

  actions do
    default_accept [:id, :name, :embedding]
    defaults [:create]

    read :read do
      primary? true
    end

    read :semantic_search do
      argument :query_vector, {:array, :float}, allow_nil?: false
      argument :k, :integer, allow_nil?: false
      prepare {AshArcadic.Preparations.VectorSearch, index: :embedding}
    end
  end
end
