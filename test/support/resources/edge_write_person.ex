defmodule AshArcadic.Test.EdgeWritePerson do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    # IntegrationClient (NOT MockClient) — resolves the throwaway :integration_database
    # so the Ash writes and the test's `admin` conn read the SAME graph.
    client(AshArcadic.Test.IntegrationClient)
    label(:EWPerson)

    edge :friends do
      label(:KNOWS)
      direction(:outgoing)
      destination(AshArcadic.Test.EdgeWritePerson)
      properties([:since])
    end

    # multiple? true → CREATE (parallel edges), NOT MERGE. Exercises the S2-1/S2-2
    # parallel-edge capability end-to-end (spec §10 CREATE multi-edge integration test).
    edge :calls do
      label(:CALLED)
      direction(:outgoing)
      destination(AshArcadic.Test.EdgeWritePerson)
      multiple?(true)
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
      argument :since, :string
      change {AshArcadic.Changes.CreateEdge, edge: :friends, to: :to}
    end

    update :call do
      require_atomic? false
      argument :to, {:array, :string}
      change {AshArcadic.Changes.CreateEdge, edge: :calls, to: :to}
    end
  end
end
