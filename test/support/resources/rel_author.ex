defmodule AshArcadic.Test.RelAuthor do
  @moduledoc false
  use Ash.Resource,
    domain: AshArcadic.Test.Domain,
    data_layer: AshArcadic.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelAuthor)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :name, :string, public?: true
    # Row policy gates :read on this (default true → transparent to seeding/admin).
    attribute :listed, :boolean, public?: true, default: true
    # Field-policy-protected on the belongs_to DESTINATION — the Task-4 RELATIONSHIP-PATH oracle
    # surface: `filter(RelPost, author.secret_note == x)` (§6.2/C2, reached THROUGH the belongs_to).
    attribute :secret_note, :string, public?: true
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
    has_many :posts, AshArcadic.Test.RelPost, destination_attribute: :author_id
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

  # A NON-admin actor cannot read :secret_note (the relationship-path oracle surface). Admin bypasses.
  field_policies do
    field_policy :secret_note do
      authorize_if actor_attribute_equals(:admin, true)
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    default_accept [:id, :org_id, :name, :listed, :secret_note, :note_blob]
    defaults [:read, :create]
  end
end
