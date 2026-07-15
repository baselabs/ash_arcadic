defmodule AshArcadic.Test.ReadEncodeDoc do
  @moduledoc """
  Slice 11 read-path encode-gate test resource (LIVE client, `:map` attribute). A non-UTF8 binary
  NESTED in a `:map` filter literal is not base64'd by `serialize_value` (only top-level binaries are),
  so it reaches the wire where Req/Jason raises `Jason.EncodeError` with the bytes in its message —
  a value leak (AGENTS.md Rule 4) AND an uncaught crash. `read_encode_gate/1` catches it value-free
  BEFORE the wire at every read `Arcadic.query` site.
  """
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:ReadEncodeDoc)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :data, :map, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept [:id, :org_id, :data]
    defaults [:create]

    read :read do
      primary? true
      pagination keyset?: true, offset?: true, countable: true, required?: false
    end
  end
end
