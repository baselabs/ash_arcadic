defmodule AshArcadic.Test.AttributeDoc do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:AttributeDoc)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :name, :string, public?: true
    attribute :amount, :integer, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept [:id, :org_id, :name, :amount]
    defaults [:create, :update, :destroy]

    # Offset pagination with count so a `page: [count: true]` read exercises the
    # run_aggregate_query/3 count path. required?: false keeps pagination OPTIONAL — a
    # no-page read (`Ash.read(tenant: ...)`) still returns a plain list. Omitting it
    # defaults required? to true, which raises LimitRequired on every existing no-page
    # AttributeDoc read (verified against the existing integration suite).
    read :read do
      primary? true
      pagination offset?: true, countable: true, required?: false
    end

    create :upsert do
      upsert? true
    end
  end
end
