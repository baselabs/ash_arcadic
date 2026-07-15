defmodule AshArcadic.Test.VectorDoc do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:VectorDoc)
    vector_index(:embedding, dimensions: 3, similarity: :cosine)
    sparse_vector_index(:sparse_embedding, tokens: :tokens, weights: :weights)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org, :string, public?: true
    attribute :name, :string, public?: true
    attribute :status, :string, public?: true
    attribute :embedding, {:array, :float}, public?: true
    attribute :tokens, {:array, :integer}, public?: true
    attribute :weights, {:array, :float}, public?: true
    attribute :body, :string, public?: true

    # A :map attribute — the vehicle for the read-path encode-gate tripwire on the vector candidate
    # query (Slice 11 T5): a caller filter `meta == ^%{nested non-UTF8 binary}` rides into
    # candidate_rid_cypher's params and must fail closed value-free before the wire.
    attribute :meta, :map, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org
  end

  actions do
    default_accept [:id, :org, :name, :status, :embedding, :tokens, :weights, :body, :meta]
    defaults [:create, :update, :destroy]

    read :read do
      primary? true
    end

    # === Slice 10 Plan 2: sparse + hybrid ===

    # Tenant-scoped sparse (learned-sparse) kNN.
    read :sparse_search do
      argument :query_tokens, {:array, :integer}, allow_nil?: false
      argument :query_weights, {:array, :float}, allow_nil?: false
      argument :k, :integer, allow_nil?: false
      prepare {AshArcadic.Preparations.VectorSearch, kind: :sparse, index: :sparse_embedding}
    end

    # A :bypass sparse action WITH a caller filter — the self-injection leak-class tripwire
    # (non-empty filters, no tenant predicate from Ash, tenant present).
    read :bypass_sparse_active do
      multitenancy :bypass
      argument :query_tokens, {:array, :integer}, allow_nil?: false
      argument :query_weights, {:array, :float}, allow_nil?: false
      argument :k, :integer, allow_nil?: false
      prepare {AshArcadic.Preparations.VectorSearch, kind: :sparse, index: :sparse_embedding}
      prepare build(filter: [status: "active"])
    end

    # Deliberately cross-tenant sparse (two-part opt-in).
    read :global_sparse_search do
      multitenancy :allow_global
      argument :query_tokens, {:array, :integer}, allow_nil?: false
      argument :query_weights, {:array, :float}, allow_nil?: false
      argument :k, :integer, allow_nil?: false

      prepare {AshArcadic.Preparations.VectorSearch,
               kind: :sparse, index: :sparse_embedding, allow_global?: true}
    end

    # Tenant-scoped hybrid fusion over a dense + sparse arm.
    read :hybrid_search do
      argument :query_vector, {:array, :float}, allow_nil?: false
      argument :query_tokens, {:array, :integer}, allow_nil?: false
      argument :query_weights, {:array, :float}, allow_nil?: false
      argument :k, :integer, allow_nil?: false

      prepare {AshArcadic.Preparations.VectorSearch,
               kind: :hybrid, arms: [{:dense, :embedding}, {:sparse, :sparse_embedding}]}
    end

    # Tenant-scoped hybrid fusion over a dense + FULL-TEXT arm (the FT-arm scoping tripwire).
    read :hybrid_fulltext_search do
      argument :query_vector, {:array, :float}, allow_nil?: false
      argument :text_query, :string, allow_nil?: false
      argument :k, :integer, allow_nil?: false

      prepare {AshArcadic.Preparations.VectorSearch,
               kind: :hybrid, arms: [{:dense, :embedding}, {:fulltext, :body}]}
    end

    # Global dense+full-text hybrid — proves the FT-arm tripwire is NON-VACUOUS (the unscoped
    # result mixes tenants, so a scoped result excluding the attacker is a real isolation proof).
    read :global_hybrid_fulltext_search do
      multitenancy :allow_global
      argument :query_vector, {:array, :float}, allow_nil?: false
      argument :text_query, :string, allow_nil?: false
      argument :k, :integer, allow_nil?: false

      prepare {AshArcadic.Preparations.VectorSearch,
               kind: :hybrid,
               arms: [{:dense, :embedding}, {:fulltext, :body}],
               allow_global?: true}
    end

    # A :bypass dense+full-text hybrid: Ash adds NO tenant predicate, so ash_arcadic's self-injecting
    # candidate-set is the SOLE scoping of the full-text arm. Makes the FT-arm scoping RED-capable
    # (an :enforce action would be masked by Ash's own predicate — a weak tripwire).
    read :bypass_hybrid_fulltext_search do
      multitenancy :bypass
      argument :query_vector, {:array, :float}, allow_nil?: false
      argument :text_query, :string, allow_nil?: false
      argument :k, :integer, allow_nil?: false

      prepare {AshArcadic.Preparations.VectorSearch,
               kind: :hybrid, arms: [{:dense, :embedding}, {:fulltext, :body}]}
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
