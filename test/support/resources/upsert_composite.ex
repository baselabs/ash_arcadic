defmodule AshArcadic.Test.UpsertComposite do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:UpsertComposite)
  end

  attributes do
    attribute :region, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:region, :code, :name]
    defaults [:read, :create, :update]

    create :upsert do
      upsert? true
    end
  end
end
