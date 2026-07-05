defmodule AshArcadic.Test.EdgeSensitivePerson do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.MockClient)
    label(:ESPerson)
    sensitive([:secret])

    edge :links do
      label(:LINKS)
      destination(AshArcadic.Test.EdgeSensitivePerson)
      properties([:secret])
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :secret, :binary, public?: true
  end

  actions do
    defaults [:read]

    create :link do
      argument :secret, :binary
      argument :to, :uuid
      change {AshArcadic.Changes.CreateEdge, edge: :links, to: :to}
    end
  end
end
