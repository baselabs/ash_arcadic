defmodule AshArcadic.Integration.BulkUpsertTenantIsolationTest do
  @moduledoc """
  Security (spec §9/§13): a fabricated cross-tenant attacker cannot merge across tenants
  (bulk-upsert merge key includes the discriminator, D4/P4) nor update another tenant's rows
  via update_many (the :attribute discriminator WHERE). Non-vacuous by PK COLLISION + mutation.

  Both proofs use a COLLIDING primary key: org2 (victim) and org1 (attacker) each hold a row with
  PK "shared". ArcadeDB has no PK uniqueness, so `{id: "shared", org_id: "org1"}` and
  `{id: "shared", org_id: "org2"}` legitimately coexist in the one base DB — that coexistence IS
  `:attribute` isolation. The collision is what makes the mutation-proof non-vacuous: without the
  discriminator on the merge identity (a) / in the update WHERE (b), the attacker's statement would
  match the victim's SAME-PK row and clobber it. A distinct-PK design would let a bare PK mismatch
  (not the guard) exclude the victim, so dropping the guard would NOT redden the test.

  The victim (org2) is seeded FIRST and independently — never a loaded victim reused as the attacker
  (whose __metadata__.tenant would scope legitimately). A telemetry-span assertion pins each proof to
  the target callback (bulk_create's bulk-upsert branch / update_many/3), so a silent fall-through to
  a different, already-isolated callback would fail rather than pass vacuously.
  """
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Test.AttributeDoc, as: P

  # :attribute tenancy shares ONE base DB; the discriminator (:org_id) scopes rows. DETACH DELETE all
  # AttributeDoc nodes after each test — no per-test DB reset, so a shared base DB would accumulate.
  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:AttributeDoc) DETACH DELETE n") end)
    :ok
  end

  defp attach_span(event, tag) do
    parent = self()
    handler_id = "#{tag}-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [event],
      fn _event, _measurements, meta, _config -> send(parent, {tag, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "bulk upsert under org1 with an org2-colliding PK creates a NEW org1 row, never hijacks org2" do
    # Victim: an org2 row PK "shared" (seeded FIRST, independently — the fabricated attacker below
    # never reuses this loaded record).
    P
    |> Ash.Changeset.for_create(:create, %{id: "shared", name: "victim"})
    |> Ash.create!(tenant: "org2")

    attach_span([:ash_arcadic, :bulk_create, :stop], :bulk_create_span)

    # Attacker: bulk-upsert PK "shared" under org1. Merge key {id, org_id} (D4) does not match org2's
    # {id: "shared", org_id: "org2"} → org1 gets its OWN row (CREATE branch), never an ON MATCH clobber.
    %Ash.BulkResult{status: :success} =
      Ash.bulk_create([%{id: "shared", name: "attacker"}], P, :upsert,
        upsert?: true,
        upsert_fields: [:name],
        tenant: "org1",
        return_records?: true
      )

    # Non-vacuity: the bulk-upsert branch of bulk_create/2 actually ran (bulk_upsert? true), not a
    # per-record create fallback — proves the code under test carried the D4-scoped MERGE identity.
    assert_receive {:bulk_create_span, %{bulk_upsert?: true, result: :ok}}

    # org2 UNCHANGED (D4): the merge identity's discriminator kept the attacker off org2's row.
    # MUTATION PROOF: making upsert_identity_keys/2 return base_keys for :attribute (dropping the
    # discriminator append in lib/ash_arcadic/data_layer.ex) makes the org1 MERGE MATCH org2's
    # id-only "shared" row and ON MATCH SET name → "attacker", reddening this assertion.
    assert Ash.get!(P, "shared", tenant: "org2").name == "victim"

    # org1 got its OWN independent row under the colliding PK.
    assert Ash.get!(P, "shared", tenant: "org1").name == "attacker"
  end

  test "update_many under org1 with a colliding PK never touches an org2 row" do
    # Both tenants hold PK "shared" (COLLISION). Seed org2 (victim) FIRST and independently.
    P
    |> Ash.Changeset.for_create(:create, %{id: "shared", name: "victim"})
    |> Ash.create!(tenant: "org2")

    P
    |> Ash.Changeset.for_create(:create, %{id: "shared", name: "orig"})
    |> Ash.create!(tenant: "org1")

    org1_row = Ash.get!(P, "shared", tenant: "org1")

    attach_span([:ash_arcadic, :update_many, :stop], :update_many_span)

    # CONFIRMED routing (Task 1): Ash.update_many/4 (a list of {record, input} tuples, strategy:
    # :atomic) reaches update_many/3. Ash.bulk_update would route to update_query (a DIFFERENT,
    # already-isolated callback) and prove nothing here. The span assertion below pins it to
    # update_many/3 — a fall-through to update_query/:stream emits a different span and never arrives.
    Ash.update_many([{org1_row, %{name: "changed"}}], P, :update,
      strategy: :atomic,
      tenant: "org1",
      return_records?: true
    )

    # Non-vacuity: our update_many/3 span fired.
    assert_receive {:update_many_span, %{result: :ok}}

    # org1's own "shared" row updated.
    assert Ash.get!(P, "shared", tenant: "org1").name == "changed"

    # org2 UNCHANGED (the :attribute discriminator WHERE scoped the UNWIND MATCH to org1).
    # MUTATION PROOF: making update_many_scope/3 return a bare {pattern, "", %{}} for :attribute
    # (dropping `WHERE n.org_id = $tenant`) makes the UNWIND MATCH both "shared" rows and clobber
    # org2's name → "changed", reddening this assertion.
    assert Ash.get!(P, "shared", tenant: "org2").name == "victim"
  end
end
