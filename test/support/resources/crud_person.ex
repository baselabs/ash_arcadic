defmodule AshArcadic.Test.CrudPerson do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:CrudPerson)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :age, :integer, public?: true
    attribute :born, :date, public?: true
    attribute :amount, :decimal, public?: true
  end

  actions do
    default_accept [:id, :name, :age, :born, :amount]
    defaults [:read, :create, :update, :destroy]
  end
end
