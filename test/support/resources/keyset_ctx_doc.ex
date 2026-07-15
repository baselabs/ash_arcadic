defmodule AshArcadic.Test.KeysetCtxDoc do
  @moduledoc """
  Slice 11 keyset test resource with `:context` (physical DB-per-tenant) multitenancy — the `:context`
  cell of the Task-4 keyset cross-tenant isolation matrix. Same keyset-enabled read action as KeysetDoc.
  """
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:KeysetCtxDoc)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :score, :integer, public?: true
  end

  multitenancy do
    strategy :context
  end

  actions do
    default_accept [:id, :score]
    defaults [:create]

    read :read do
      primary? true
      pagination keyset?: true, offset?: true, countable: true, required?: false
    end
  end
end
