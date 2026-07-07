defmodule AshArcadic.Test.RelMixedAttrPost do
  @moduledoc false
  # Mixed strategy-pair matrix (:attribute source → :context destination). An :attribute-multitenant
  # SOURCE whose belongs_to targets the :context RelMixedCtxAuthor. Loading :author with a tenant must
  # re-target the nested read to the tenant's physical database (never the base DB). NO policies.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelMixedAttrPost)
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
    belongs_to :author, AshArcadic.Test.RelMixedCtxAuthor,
      attribute_type: :string,
      source_attribute: :author_id,
      destination_attribute: :id
  end

  actions do
    default_accept [:id, :org_id, :title, :author_id]
    defaults [:read, :create]
  end
end
