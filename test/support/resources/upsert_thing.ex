defmodule AshArcadic.Test.UpsertThing do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:UpsertThing)
  end

  attributes do
    attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    # Drives upsert_condition tests (a condition over the EXISTING row's value).
    attribute :version, :integer, public?: true
  end

  actions do
    default_accept [:code, :name, :version]
    defaults [:read, :create]

    create :upsert do
      upsert? true
    end
  end
end
