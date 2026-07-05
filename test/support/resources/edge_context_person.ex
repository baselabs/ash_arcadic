defmodule AshArcadic.Test.EdgeContextPerson do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    # IntegrationClient (NOT MockClient) — resolves the throwaway :integration_database.
    # :context re-targets each write to the per-tenant database via write_conn.
    client(AshArcadic.Test.IntegrationClient)
    label(:ECPerson)

    edge :friends do
      label(:KNOWS)
      direction(:outgoing)
      destination(AshArcadic.Test.EdgeContextPerson)
    end
  end

  multitenancy do
    strategy :context
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:id, :name]
    defaults [:read, :create]

    update :befriend do
      require_atomic? false
      argument :to, {:array, :string}
      change {AshArcadic.Changes.CreateEdge, edge: :friends, to: :to}
    end
  end
end
