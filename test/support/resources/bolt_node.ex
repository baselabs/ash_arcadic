defmodule AshArcadic.Test.BoltNode do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  defmodule Client do
    @moduledoc false
    @behaviour AshArcadic.Client

    @impl true
    def transport, do: Arcadic.Transport.Bolt

    @impl true
    def conn do
      Arcadic.connect("bolt://localhost:7687", "example",
        auth: {"test", "unused"},
        transport: transport()
      )
    end
  end

  arcade do
    client Client
  end

  attributes do
    uuid_primary_key :id
  end
end
