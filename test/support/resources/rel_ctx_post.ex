defmodule AshArcadic.Test.RelCtxPost do
  @moduledoc false
  # :context variant of RelPost — for the strategy-pair matrix only (no field policy).
  use Ash.Resource,
    domain: AshArcadic.Test.Domain,
    data_layer: AshArcadic.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelCtxPost)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :secret_tag, :string, public?: true
  end

  multitenancy do
    strategy :context
  end

  relationships do
    belongs_to :author, AshArcadic.Test.RelCtxAuthor,
      attribute_type: :string,
      source_attribute: :author_id,
      destination_attribute: :id
  end

  policies do
    bypass actor_attribute_equals(:admin, true) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end

  actions do
    default_accept [:id, :title, :author_id, :secret_tag]
    defaults [:read, :create]
  end
end
