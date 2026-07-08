defmodule AshArcadic.Test.FkSensitivePost do
  @moduledoc false
  # :author_id is a SENSITIVE :binary FK, declared with NO belongs_to back — so ValidateRelationshipFk
  # cannot see it as a join attr at compile (the CV-3 residual). Loading FkSensitiveAuthor.posts builds
  # `author_id IN [plaintext pks]` over an encrypted column → the Slice-6 guard fails it closed loud.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:FkSensitivePost)
    sensitive([:author_id])
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :author_id, :binary, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept [:id, :org_id, :author_id]
    defaults [:read, :create]
  end
end
