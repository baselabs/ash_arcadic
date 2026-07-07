defmodule AshArcadic.Test.RelTag do
  @moduledoc false
  # m2m endpoint for the Slice-5 Task-5 many_to_many matrix. :attribute multitenancy; NO sensitive
  # attrs (ValidateRelationshipFk from Task 1 rejects a sensitive join key). Loaded from RelPost via
  # the two-`IN` join path (join-resource read → endpoint read), each tenant-scoped.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelTag)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :name, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  relationships do
    many_to_many :posts, AshArcadic.Test.RelPost,
      through: AshArcadic.Test.RelPostTag,
      source_attribute_on_join_resource: :tag_id,
      destination_attribute_on_join_resource: :post_id
  end

  actions do
    default_accept [:id, :org_id, :name]
    defaults [:read, :create]
  end
end
