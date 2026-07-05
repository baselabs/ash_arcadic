defmodule AshArcadic.Test.EncodeDoc do
  @moduledoc false
  # A resource with a `:map` attribute — the vector for the JSON-encode leak: a raw
  # non-UTF8 binary nested inside a `:map`/`:list` value is not base64'd by
  # serialize_value (only top-level binaries are), so it reaches the wire and
  # Jason.EncodeError would embed the bytes in its message (AGENTS.md Rule 4).
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.MockClient)
    label(:EncodeDoc)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :data, :map, public?: true
  end

  actions do
    default_accept [:id, :data]
    defaults [:read, :create, :update, :destroy]

    create :upsert do
      upsert? true
    end
  end
end
