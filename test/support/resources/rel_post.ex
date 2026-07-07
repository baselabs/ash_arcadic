defmodule AshArcadic.Test.RelPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshArcadic.Test.Domain,
    data_layer: AshArcadic.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelPost)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :title, :string, public?: true
    # Field-policy-protected NON-FK attribute — the Task-4 field-policy-oracle surface.
    attribute :secret_tag, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  relationships do
    belongs_to :author, AshArcadic.Test.RelAuthor,
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

  # A NON-admin actor cannot read :secret_tag (the oracle surface). Admin bypasses.
  field_policies do
    field_policy :secret_tag do
      authorize_if actor_attribute_equals(:admin, true)
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    default_accept [:id, :org_id, :title, :author_id, :secret_tag]
    defaults [:read, :create]
  end
end
