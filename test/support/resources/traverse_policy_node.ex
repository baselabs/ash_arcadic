defmodule AshArcadic.Test.TraversePolicyNode do
  @moduledoc false
  use Ash.Resource,
    domain: AshArcadic.Test.Domain,
    data_layer: AshArcadic.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:TravPolNode)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :name, :string, public?: true
    attribute :visible, :boolean, public?: true, default: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  relationships do
    has_many :descendants, __MODULE__ do
      manual(
        {AshArcadic.ManualRelationships.Traverse,
         edge_label: :POL_PARENT_OF, direction: :outgoing, min_depth: 1, max_depth: 3}
      )
    end
  end

  policies do
    # Admin bypass so seeding/verification reads are unrestricted; the traversal load runs
    # as a non-admin actor to exercise the row filter.
    bypass actor_attribute_equals(:admin, true) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(visible == true)
    end
  end

  actions do
    default_accept [:id, :org_id, :name, :visible]
    defaults [:read, :create, :update, :destroy]
  end
end
