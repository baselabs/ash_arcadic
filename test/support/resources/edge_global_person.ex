defmodule AshArcadic.Test.EdgeGlobalPerson do
  @moduledoc false
  # GLOBAL (non-multitenant) source whose edges point at an `:attribute`-multitenant
  # destination (EdgeWritePerson) — the destination-only scoping shape. The edge write
  # must scope the DESTINATION endpoint by its own discriminator (fail-closed on a blank
  # tenant) and must never bind another tenant's vertex by bare PK (2026-10-16 review
  # fix; the destination-only case previously emitted no tenant clause at all).
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:EGPerson)

    edge :mentions do
      label(:MENTIONS)
      direction(:outgoing)
      destination(AshArcadic.Test.EdgeWritePerson)
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:id, :name]
    defaults [:read, :create]

    update :mention do
      require_atomic? false
      argument :to, {:array, :string}
      change {AshArcadic.Changes.CreateEdge, edge: :mentions, to: :to}
    end

    update :unmention do
      require_atomic? false
      argument :to, {:array, :string}
      change {AshArcadic.Changes.DestroyEdge, edge: :mentions, to: :to}
    end
  end
end
