defmodule AshArcadic.Test.VectorMockDoc do
  @moduledoc false
  # Non-multitenant vector resource on MockClient — lets DB-free unit tests reach the
  # vector DISPATCH (run_vector_kind/safe_vector_call) without a live server: the failure
  # classes under test fire client-side (arcadic's argument validators) or at param
  # encoding (before any network attempt), so the unreachable shared-server URL is
  # never contacted.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.MockClient)
    label(:VectorMockDoc)
    vector_index(:embedding, dimensions: 3, similarity: :cosine)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :embedding, {:array, :float}, public?: true
  end

  actions do
    default_accept [:id, :name, :embedding]
    defaults [:create]

    read :read do
      primary? true
    end
  end
end
