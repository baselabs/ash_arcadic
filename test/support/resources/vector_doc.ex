defmodule AshArcadic.Test.VectorDoc do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:VectorDoc)
    vector_index(:embedding, dimensions: 3, similarity: :cosine)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org, :string, public?: true
    attribute :name, :string, public?: true
    attribute :status, :string, public?: true
    attribute :embedding, {:array, :float}, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org
  end

  actions do
    default_accept [:id, :org, :name, :status, :embedding]
    defaults [:create, :update, :destroy]

    read :read do
      primary? true
    end

    # Tenant-scoped dense kNN (the default posture).
    read :semantic_search do
      argument :query_vector, {:array, :float}, allow_nil?: false
      argument :k, :integer, allow_nil?: false
      prepare {AshArcadic.Preparations.VectorSearch, index: :embedding}
    end

    # A tenant-scoped search that also carries a caller filter via prepare/before-action.
    read :semantic_search_active do
      argument :query_vector, {:array, :float}, allow_nil?: false
      argument :k, :integer, allow_nil?: false
      prepare {AshArcadic.Preparations.VectorSearch, index: :embedding}
      prepare build(filter: [status: "active"])
    end

    # Deliberately cross-tenant: the action permits a no-tenant read AND the preparation opts in.
    read :global_semantic_search do
      multitenancy :allow_global
      argument :query_vector, {:array, :float}, allow_nil?: false
      argument :k, :integer, allow_nil?: false
      prepare {AshArcadic.Preparations.VectorSearch, index: :embedding, allow_global?: true}
    end

    # A :bypass action WITHOUT allow_global? on the preparation, carrying a caller filter — the
    # self-injection tripwire (T-b): non-empty filters, no tenant predicate from Ash, tenant present.
    read :bypass_search_active do
      multitenancy :bypass
      argument :query_vector, {:array, :float}, allow_nil?: false
      argument :k, :integer, allow_nil?: false
      prepare {AshArcadic.Preparations.VectorSearch, index: :embedding}
      prepare build(filter: [status: "active"])
    end
  end
end
