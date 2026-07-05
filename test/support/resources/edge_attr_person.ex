defmodule AshArcadic.Test.EdgeAttrPerson do
  @moduledoc false
  use Ash.Resource,
    domain: AshArcadic.Test.Domain,
    data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.MockClient)
    label(:EAPerson)

    edge :friends do
      label(:KNOWS)
      direction(:outgoing)
      destination(AshArcadic.Test.EdgeAttrPerson)
      properties([:since])
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :name, :string, public?: true
    attribute :tenant, :string, public?: true
  end

  actions do
    defaults [:read, :create, :update, :destroy]
  end
end
