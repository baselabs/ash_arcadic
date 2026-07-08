defmodule AshArcadic.Test.FkSensitiveAuthor do
  @moduledoc false
  # CV-3 residual fixture: a has_many whose destination_attribute (:author_id, on the POST) is
  # `sensitive` on the destination with NO inverse belongs_to — uncatchable by ValidateRelationshipFk
  # at compile (per-resource local check). The runtime In-clause guard (Slice-6) fails the LOAD closed.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:FkSensitiveAuthor)
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
    # `destination_attribute: :author_id` is a SENSITIVE :binary FK on the POST while this source's PK
    # (:id) is :string — an INTENTIONAL type divergence (this codebase's "sensitive = encrypted-binary"
    # model), so opt out of Ash-core's built-in type-compat check. This declares the intent; it does NOT
    # weaken the CV-3 residual (AshArcadic's ValidateRelationshipFk is a separate verifier that still
    # cannot see the remote sensitive dest attr at compile) nor change runtime (the load still builds
    # `author_id IN [pks]`, which the Slice-6 guard fails closed loud).
    has_many :posts, AshArcadic.Test.FkSensitivePost,
      destination_attribute: :author_id,
      validate_destination_attribute?: false
  end

  actions do
    default_accept [:id, :org_id, :name]
    defaults [:read, :create]
  end
end
