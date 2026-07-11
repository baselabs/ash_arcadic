defmodule AshArcadic.Integration.UpdateManyCustomTenantTest do
  @moduledoc false
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Test.CustomTenantDoc
  alias AshArcadic.Test.OrgRef

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CustomTenantDoc) DETACH DELETE n") end)
    :ok
  end

  # Regression (CV-5): run_update_many scoped by the RAW `opts.tenant` (here `%OrgRef{}`), NOT the
  # ToTenant-normalized value. Ash stores the `:attribute` discriminator as
  # parse_attribute(changeset.to_tenant) = the bare id string (create.ex), and both the single-row and
  # bulk-upsert write paths scope by that same normalized `changeset.to_tenant`. Scoping update_many by
  # the raw struct instead makes `n.org_id = $tenant` bind a struct that never matches the stored
  # string discriminator → a silent no-op (its non-encodable struct also poisons the $tenant param).
  # The fix scopes by `rep.to_tenant`, restoring sibling parity so a custom Ash.ToTenant update_many
  # matches and mutates.
  test "update_many scopes by the NORMALIZED tenant under a custom Ash.ToTenant (struct tenant)" do
    tenant = %OrgRef{id: "org1"}

    CustomTenantDoc
    |> Ash.Changeset.for_create(:create, %{id: "x", name: "orig"})
    |> Ash.create!(tenant: tenant)

    rec = Ash.get!(CustomTenantDoc, "x", tenant: tenant)

    result =
      Ash.update_many([{rec, %{name: "updated"}}], CustomTenantDoc, :update,
        strategy: :atomic,
        tenant: tenant,
        return_records?: true,
        return_errors?: true
      )

    # With the raw-tenant bug the data layer no-ops (or errors on the struct param) → the row is never
    # updated. Scoping by the normalized to_tenant matches the stored "org1" discriminator and mutates.
    assert result.status == :success
    assert Ash.get!(CustomTenantDoc, "x", tenant: tenant).name == "updated"
  end
end
