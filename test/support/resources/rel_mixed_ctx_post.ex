defmodule AshArcadic.Test.RelMixedCtxPost do
  @moduledoc false
  # Mixed strategy-pair matrix (:context source → :attribute destination). A :context-multitenant
  # SOURCE whose belongs_to targets the :attribute RelMixedAttrAuthor. The source read runs in the
  # tenant's physical database; the nested :attribute destination read carries the org_id filter. NO
  # policies. Mirrors RelCtxPost's shape (no org_id attr).
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelMixedCtxPost)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
  end

  multitenancy do
    strategy :context
  end

  relationships do
    belongs_to :author, AshArcadic.Test.RelMixedAttrAuthor,
      attribute_type: :string,
      source_attribute: :author_id,
      destination_attribute: :id
  end

  actions do
    default_accept [:id, :title, :author_id]
    defaults [:read, :create]
  end
end
