defmodule AshArcadic.Test.CalcTenantPerson do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:CalcTenantPerson)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :a, :integer, public?: true
    attribute :b, :integer, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  calculations do
    calculate :total, :integer, expr(a + b), public?: true
  end

  actions do
    default_accept [:id, :org_id, :a, :b]
    defaults [:create, :read, :update, :destroy]
  end
end
