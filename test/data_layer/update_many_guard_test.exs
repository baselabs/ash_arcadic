defmodule AshArcadic.DataLayer.UpdateManyGuardTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Errors.UpdateFailed

  # An `:attribute`-multitenant resource on MockClient. The D3 discriminator guard fires in
  # do_update_many BEFORE any connection is resolved, so these units are DB-free in the GREEN state;
  # under the mutation they fall through to the write path (MockClient's bad auth), never producing the
  # guard's static reason string.
  defmodule AttrMock do
    use Ash.Resource, domain: nil, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
      label(:AttrMock)
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
  end

  # (a) D3 — a per-record change that SETs the multitenancy discriminator (org_id) is a tenant-hop and
  # must fail closed value-free. NON-VACUITY: the guard fires before any conn, so the ONLY way to get
  # this exact reason is the guard itself; forcing `if disc && ...` to `if false and ...` lets the write
  # reach MockClient's bad auth, whose redacted reason is not this string → RED.
  test "update_many fails closed when a per-record change SETs the multitenancy discriminator" do
    cs = %Ash.Changeset{
      resource: AttrMock,
      data: struct(AttrMock, %{id: "d1"}),
      attributes: %{org_id: "hop", name: "y"},
      atomics: [],
      filter: nil
    }

    assert {:error, %UpdateFailed{} = err} =
             DL.update_many(AttrMock, [cs], %{
               tenant: "org1",
               return_records?: true,
               calculations: []
             })

    assert err.reason == "cannot set the multitenancy discriminator"
  end

  # (d) An untranslatable changeset.filter (attribute-to-attribute `name == age` — a reachable
  # UnsupportedFilter the layer never advertises) must fail the bulk update closed rather than silently
  # dropping the scoping and over-updating. Basic is non-multitenant on MockClient: write_conn resolves
  # (passthrough), update_many_scope yields an empty tenant clause, and changeset_where returns
  # {:error, _} BEFORE any Arcadic.command — DB-free. NON-VACUITY: this exact reason is produced only by
  # the failing changeset_where arm; changing it reddens the assertion.
  test "update_many fails closed on an untranslatable scoping filter (never silently drops scoping)" do
    filter = Ash.Query.filter(AshArcadic.Test.Basic, name == age).filter

    cs = %Ash.Changeset{
      resource: AshArcadic.Test.Basic,
      data: struct(AshArcadic.Test.Basic, %{id: "11111111-1111-1111-1111-111111111111"}),
      attributes: %{},
      atomics: [],
      filter: filter
    }

    assert {:error, %UpdateFailed{} = err} =
             DL.update_many(AshArcadic.Test.Basic, [cs], %{
               tenant: nil,
               return_records?: true,
               calculations: []
             })

    assert err.reason == "unsupported scoping filter on bulk update"
  end
end
