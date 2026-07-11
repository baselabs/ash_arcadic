defmodule AshArcadic.Test.OrgRef do
  @moduledoc false
  # A STRUCT tenant whose Ash.ToTenant normalization maps it to a DIFFERENT term (the bare id
  # string). This makes the raw tenant (`%OrgRef{}`) and the normalized tenant (`"..."`) diverge, so a
  # write path that scopes by the raw `opts.tenant` instead of the normalized `changeset.to_tenant`
  # targets the wrong discriminator/database and silently mismatches every stored row.
  defstruct [:id]
end

defimpl Ash.ToTenant, for: AshArcadic.Test.OrgRef do
  def to_tenant(%AshArcadic.Test.OrgRef{id: id}, _resource), do: id
end

defmodule AshArcadic.Test.CustomTenantDoc do
  @moduledoc false
  # `:attribute` multitenancy whose tenant is normalized by a CUSTOM Ash.ToTenant (OrgRef → id). The
  # stored discriminator is parse_attribute(to_tenant(tenant)); update_many must scope by that same
  # normalized value.
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:CustomTenantDoc)
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
    default_accept [:id, :name]
    defaults [:read, :create, :update, :destroy]
  end
end
