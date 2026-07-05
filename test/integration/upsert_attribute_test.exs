defmodule AshArcadic.Integration.UpsertAttributeTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.AttributeDoc

  # :attribute tenancy shares ONE base DB; the discriminator scopes rows. Both
  # tests here CREATE id "x"/"y"; delete all AttributeDoc after each so a shared
  # module DB (no per-test reset) does not leak rows across tests.
  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:AttributeDoc) DETACH DELETE n") end)
    :ok
  end

  defp upsert(attrs, tenant) do
    AttributeDoc
    |> Ash.Changeset.for_create(:upsert, attrs, tenant: tenant)
    |> Ash.create()
  end

  # THE cross-tenant isolation tripwire for MERGE upsert. The MERGE identity must
  # include the tenant discriminator for :attribute resources — otherwise a
  # same-PK upsert from another tenant MATCHES the victim's row (MERGE matches on
  # PK alone) and ON MATCH SET mutates/moves it. Non-vacuous: with a PK-only MERGE
  # identity, org2's upsert hijacks org1's row (name→"HACKED", org_id→"org2") and
  # org1's read returns [] instead of ["A"].
  test "TRIPWIRE: a same-PK upsert from another tenant cannot match or mutate the victim tenant's row" do
    {:ok, _} = upsert(%{id: "x", name: "A"}, "org1")

    # org2 upserts the SAME primary key with different data.
    {:ok, _} = upsert(%{id: "x", name: "HACKED"}, "org2")

    # org1's row is untouched — org2's upsert created its OWN row, it did not
    # MERGE-match across the tenant boundary.
    {:ok, org1_rows} = AttributeDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: "org1")
    assert Enum.map(org1_rows, & &1.name) == ["A"]
    assert Enum.map(org1_rows, & &1.org_id) == ["org1"]

    # org2 has its own independent row under the same PK.
    {:ok, org2_rows} = AttributeDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: "org2")
    assert Enum.map(org2_rows, & &1.name) == ["HACKED"]
    assert Enum.map(org2_rows, & &1.org_id) == ["org2"]
  end

  # Positive control: a same-tenant upsert replay MUST still be idempotent (ON
  # MATCH updates the one in-tenant row), proving the tenant-scoped identity does
  # not over-partition and break in-tenant upsert semantics.
  test "same-tenant upsert replay is idempotent (ON MATCH updates the single in-tenant row)" do
    {:ok, _} = upsert(%{id: "y", name: "First"}, "org1")
    {:ok, _} = upsert(%{id: "y", name: "Second"}, "org1")

    {:ok, rows} = AttributeDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: "org1")
    assert Enum.map(rows, & &1.name) == ["Second"]
    assert length(rows) == 1
  end
end
