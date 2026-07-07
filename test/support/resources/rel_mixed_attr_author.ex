defmodule AshArcadic.Test.RelMixedAttrAuthor do
  @moduledoc false
  # Mixed strategy-pair matrix (:context source → :attribute destination). The :attribute DESTINATION
  # of RelMixedCtxPost's belongs_to. Isolation is the org_id discriminator filter Ash injects on the
  # nested read. NO policies.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelMixedAttrAuthor)
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

  actions do
    default_accept [:id, :org_id, :name]
    defaults [:read, :create]
  end
end
