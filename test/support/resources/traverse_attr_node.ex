defmodule AshArcadic.Test.TraverseAttrNode do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:TravAttrNode)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :name, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  relationships do
    has_many :descendants, __MODULE__ do
      manual(
        {AshArcadic.ManualRelationships.Traverse,
         edge_label: :PARENT_OF, direction: :outgoing, min_depth: 1, max_depth: 3}
      )
    end
  end

  actions do
    default_accept [:id, :org_id, :name]
    defaults [:read, :create, :update, :destroy]
  end
end
