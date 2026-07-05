defmodule AshArcadic.Test.TraverseAttrTeam do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:TravAttrTeam)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :team_id, :string, public?: true
    attribute :name, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :team_id
  end

  actions do
    default_accept [:id, :team_id, :name]
    defaults [:read, :create, :update, :destroy]
  end
end
