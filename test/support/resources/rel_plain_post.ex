defmodule AshArcadic.Test.RelPlainPost do
  @moduledoc false
  # NON-policy variant of RelPost (no authorizers) — the belongs_to SOURCE whose source-on-related
  # filter to RelPlainAuthor is ALLOWED under the Slice-5 fail-closed guard.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelPlainPost)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :title, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  relationships do
    belongs_to :author, AshArcadic.Test.RelPlainAuthor,
      attribute_type: :string,
      source_attribute: :author_id,
      destination_attribute: :id
  end

  actions do
    default_accept [:id, :org_id, :title, :author_id]
    defaults [:read, :create]
  end
end
