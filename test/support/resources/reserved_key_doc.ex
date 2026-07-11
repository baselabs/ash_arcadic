defmodule AshArcadic.Test.ReservedKeyDoc do
  @moduledoc """
  Pathological fixture: the primary key is literally named `:set` and there is an
  attribute named `:all` — the two bulk-write container keys. Proves the bulk-write
  row maps namespace their containers so a same-named PK/attr cannot collide.
  """
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:ReservedKeyDoc)
  end

  attributes do
    attribute :set, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :all, :string, public?: true
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:set, :all, :name]
    defaults [:read, :create, :update, :destroy]

    create :upsert do
      upsert? true
    end
  end
end
