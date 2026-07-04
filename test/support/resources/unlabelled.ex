defmodule AshArcadic.Test.Unlabelled do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.MockClient)
  end

  attributes do
    uuid_primary_key :id
  end
end
