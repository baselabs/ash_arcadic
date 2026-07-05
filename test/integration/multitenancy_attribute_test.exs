defmodule AshArcadic.Integration.MultitenancyAttributeTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.AttributeDoc

  # :attribute tenancy shares ONE base DB (the discriminator scopes rows within it),
  # and IntegrationCase gives a MODULE-scoped DB with no per-test reset. Both tests
  # here CREATE an id "a1"; without cleanup the second create would leak a duplicate
  # into the first test's read set under ExUnit's random order. Delete all AttributeDoc
  # after each test so every test starts from a clean DB.
  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:AttributeDoc) DETACH DELETE n") end)
    :ok
  end

  # Unwraps Ash's outer Invalid wrapper to the inner StaleRecord (same shape as
  # update_test.exs). StaleRecord is the data-layer signal that the SCOPED query
  # RAN and matched 0 rows — the proof that changeset_where AND-composed the
  # injected tenant filter, not that Ash rejected the mutation before the data layer.
  defp stale_record?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale_record?(%{errors: errors}), do: Enum.any?(errors, &stale_record?/1)
  defp stale_record?(_), do: false

  test "reads are scoped to the tenant discriminator (Ash-core-injected filter → scoped WHERE)" do
    {:ok, _} =
      AttributeDoc
      |> Ash.Changeset.for_create(:create, %{id: "a1", name: "A"}, tenant: "org1")
      |> Ash.create()

    {:ok, _} =
      AttributeDoc
      |> Ash.Changeset.for_create(:create, %{id: "a2", name: "B"}, tenant: "org2")
      |> Ash.create()

    {:ok, org1} = AttributeDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: "org1")
    {:ok, org2} = AttributeDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: "org2")

    assert Enum.map(org1, & &1.name) == ["A"]
    assert Enum.map(org2, & &1.name) == ["B"]
  end

  test "TRIPWIRE: a fabricated cross-tenant update/destroy is denied — the injected discriminator scopes the WHERE to 0 rows (StaleRecord), never a silent unscoped mutation" do
    {:ok, victim} =
      AttributeDoc
      |> Ash.Changeset.for_create(:create, %{id: "a1", name: "A"}, tenant: "org1")
      |> Ash.create()

    # Attacker (org2) fabricates a changeset carrying the victim's PK. A fabricated
    # `struct/2` is used deliberately (the ash_age idiom): a record LOADED under a
    # tenant carries `__metadata__.tenant`, which Ash's destroy honors OVER the passed
    # tenant — that would scope to the record's OWN tenant and delete its own row (a
    # legitimate self-delete, not the cross-tenant threat). The fabricated struct has
    # no metadata tenant, so `tenant: "org2"` sticks and Ash injects org_id == "org2".
    # a1's stored org_id is "org1" → the scoped WHERE matches 0 rows → the data layer
    # fails closed as StaleRecord (the mutation RAN scoped and hit nothing; it was NOT
    # rejected upstream by Ash — that would leave changeset_where unexercised).
    upd_err =
      struct(AttributeDoc, id: "a1", org_id: "org2", name: "A")
      |> Ash.Changeset.for_update(:update, %{name: "hacked"}, tenant: "org2")
      |> Ash.update()

    assert {:error, upd_err} = upd_err

    assert stale_record?(upd_err),
           "expected StaleRecord (scoped query matched 0 rows), got: #{inspect(upd_err)}"

    del_err =
      struct(AttributeDoc, id: "a1", org_id: "org2", name: "A")
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: "org2")
      |> Ash.destroy()

    assert {:error, del_err} = del_err

    assert stale_record?(del_err),
           "expected StaleRecord (scoped query matched 0 rows), got: #{inspect(del_err)}"

    # org1's row survives both denied cross-tenant attempts (unchanged, not deleted).
    {:ok, [reloaded]} = AttributeDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: "org1")
    assert reloaded.name == "A"

    # Positive control: the SAME injected-filter path must ALLOW an in-tenant update
    # and destroy — proving the scoping denies cross-tenant WITHOUT over-denying (a
    # filter that scoped everything to 0 rows would pass the denial asserts vacuously).
    {:ok, updated} =
      victim
      |> Ash.Changeset.for_update(:update, %{name: "renamed"}, tenant: "org1")
      |> Ash.update()

    assert updated.name == "renamed"

    :ok = victim |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: "org1") |> Ash.destroy()
    {:ok, []} = AttributeDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: "org1")
  end
end
