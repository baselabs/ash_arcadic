defmodule AshArcadic.Test.RelMixedCtxAuthor do
  @moduledoc false
  # Mixed strategy-pair matrix (:attribute source → :context destination). The :context DESTINATION
  # of RelMixedAttrPost's belongs_to. NO policies — isolation here is the physical per-tenant
  # database, exercised by a LOAD from an :attribute source that must resolve the tenant DB (never
  # the base DB) or fail closed :tenant_required. Mirrors RelCtxAuthor's shape (no org_id attr).
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:RelMixedCtxAuthor)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  multitenancy do
    strategy :context
  end

  actions do
    default_accept [:id, :name]
    defaults [:read, :create]
  end
end
