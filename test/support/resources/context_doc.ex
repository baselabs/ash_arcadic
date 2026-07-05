defmodule AshArcadic.Test.ContextDoc do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:ContextDoc)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  multitenancy do
    strategy :context
  end

  actions do
    default_accept [:id, :name]
    defaults [:read, :create, :update, :destroy]
  end
end
