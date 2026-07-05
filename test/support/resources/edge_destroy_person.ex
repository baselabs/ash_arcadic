defmodule AshArcadic.Test.EdgeDestroyPerson do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    # IntegrationClient (NOT MockClient) — resolves the throwaway :integration_database
    # so the Ash writes and the test's `admin` conn read the SAME graph.
    client(AshArcadic.Test.IntegrationClient)
    label(:EDPerson)

    edge :friends do
      label(:KNOWS)
      direction(:outgoing)
      destination(AshArcadic.Test.EdgeDestroyPerson)
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :tenant, :string, public?: true
  end

  actions do
    default_accept [:id, :name, :tenant]
    defaults [:read, :create]

    update :befriend do
      require_atomic? false
      argument :to, {:array, :string}
      change {AshArcadic.Changes.CreateEdge, edge: :friends, to: :to}
    end

    update :unfriend do
      require_atomic? false
      argument :to, {:array, :string}
      change {AshArcadic.Changes.DestroyEdge, edge: :friends, to: :to}
    end
  end
end
