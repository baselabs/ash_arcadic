defmodule AshArcadic.Test.RelCtxAuthor do
  @moduledoc false
  # :context variant of RelAuthor — for the strategy-pair matrix only (no field policy).
  use Ash.Resource,
    domain: AshArcadic.Test.Domain,
    data_layer: AshArcadic.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelCtxAuthor)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    # Row policy gates :read on this (default true → transparent to seeding/admin).
    attribute :listed, :boolean, public?: true, default: true
    attribute :secret_note, :string, public?: true
  end

  multitenancy do
    strategy :context
  end

  relationships do
    has_many :posts, AshArcadic.Test.RelCtxPost, destination_attribute: :author_id
  end

  aggregates do
    count :post_count, :posts
  end

  policies do
    bypass actor_attribute_equals(:admin, true) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(listed == true)
    end
  end

  actions do
    default_accept [:id, :name, :listed, :secret_note]
    defaults [:read, :create]
  end
end
