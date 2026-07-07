defmodule AshArcadic.Test.RelPostTag do
  @moduledoc false
  # m2m JOIN resource for RelPost <-> RelTag. Property-FK join (`:attribute` strategy, no edges).
  # Both join FKs (post_id/tag_id) are plaintext strings — NOT sensitive (ValidateRelationshipFk
  # would reject a sensitive join key). Read tenant-scoped via org_id.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelPostTag)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :post_id, :string, public?: true
    attribute :tag_id, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  relationships do
    belongs_to :post, AshArcadic.Test.RelPost,
      attribute_type: :string,
      source_attribute: :post_id,
      destination_attribute: :id,
      define_attribute?: false

    belongs_to :tag, AshArcadic.Test.RelTag,
      attribute_type: :string,
      source_attribute: :tag_id,
      destination_attribute: :id,
      define_attribute?: false
  end

  actions do
    default_accept [:id, :org_id, :post_id, :tag_id]
    defaults [:read, :create]
  end
end
