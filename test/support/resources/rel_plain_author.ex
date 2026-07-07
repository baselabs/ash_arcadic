defmodule AshArcadic.Test.RelPlainAuthor do
  @moduledoc false
  # NON-policy variant of RelAuthor: no authorizers, so a source-on-related filter to it is
  # ALLOWED (the Slice-5 fail-closed guard only rejects policy-bearing destinations). Substrate
  # for the migrated Task-3 filter/operator-matrix/telemetry tests + the filter-path isolation test.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelPlainAuthor)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :name, :string, public?: true
    # :binary attr — a range op on it PARSES past Ash's {:filter_expr} gate but is rejected by
    # AshArcadic.Query.Filter's range-comparable guard (§6.3 operator-matrix; base64 is not
    # byte-order-preserving). Drives the fail-closed %UnsupportedFilter{} on the NESTED read.
    attribute :note_blob, :binary, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  relationships do
    has_many :posts, AshArcadic.Test.RelPlainPost, destination_attribute: :author_id
  end

  actions do
    default_accept [:id, :org_id, :name, :note_blob]
    defaults [:read, :create]
  end
end
