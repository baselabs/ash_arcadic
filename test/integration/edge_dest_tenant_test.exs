defmodule AshArcadic.Integration.EdgeDestTenantTest do
  @moduledoc """
  Destination-only `:attribute` multitenancy on edge writes (the 2026-10-16 review fix):
  a GLOBAL source linking an `:attribute`-multitenant destination must scope the
  destination endpoint by its OWN discriminator — fail-closed on a blank tenant, and
  never bind another tenant's vertex by bare destination PK. Before the fix this shape
  emitted NO tenant clause at all: the MATCH bound any tenant's vertex with a known PK,
  a cross-tenant edge write (create AND destroy).
  """
  use AshArcadic.Test.IntegrationCase
  alias AshArcadic.Test.EdgeGlobalPerson

  defp count_mentions(admin, from_id) do
    {:ok, [%{"c" => c}]} =
      Arcadic.query(admin, "MATCH (a:EGPerson {id:$id})-[e:MENTIONS]->() RETURN count(e) AS c", %{
        "id" => from_id
      })

    c
  end

  setup %{admin: admin} do
    on_exit(fn ->
      Arcadic.command!(admin, "MATCH (n:EGPerson) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:EWPerson) DETACH DELETE n")
    end)
  end

  test "a blank tenant fails closed before any write (destination-only multitenancy)", %{
    admin: admin
  } do
    {:ok, g} = create_global("g")
    # The victim row exists; the edge action runs WITHOUT a tenant.
    Arcadic.command!(admin, "CREATE (n:EWPerson {id:'victim', tenant:'org2', name:'v'})")

    assert {:error, error} = mention(g, ["victim"], nil)
    assert error_message(error) =~ "tenant required"
    assert count_mentions(admin, "g") == 0
  end

  test "an EMPTY to: list succeeds without a tenant (the documented no-op contract)", %{
    admin: admin
  } do
    # Delta-review catch: the destination-only tenancy fix made the blank-tenant check
    # fire even when there is NOTHING to write — an empty `to:` must stay a success.
    {:ok, g} = create_global("g")

    assert {:ok, _} = mention(g, [], nil)
    assert {:ok, _} = Ash.Changeset.for_update(g, :unmention, %{to: []}) |> Ash.update()
    assert count_mentions(admin, "g") == 0
  end

  test "a cross-tenant destination is NOT reachable by bare PK (create + destroy)", %{
    admin: admin
  } do
    # Victim row FIRST (adversarial ordering), then the attacker's global source.
    Arcadic.command!(admin, "CREATE (n:EWPerson {id:'victim', tenant:'org2', name:'v'})")
    {:ok, g} = create_global("g")

    # The attacker's tenant is org1; the victim row lives in org2. The old code bound
    # `b.id = $dst` with NO tenant clause and linked the victim.
    assert {:error, _} = mention(g, ["victim"], "org1")
    assert count_mentions(admin, "g") == 0

    # With the victim's own tenant the link succeeds (same resource, same PK) — the
    # scoping is by tenant, not by PK existence.
    assert {:ok, _} = mention(g, ["victim"], "org2")
    assert count_mentions(admin, "g") == 1

    # Destroy honors the same per-endpoint scoping: org1 cannot delete org2's edge.
    assert {:error, _} = unmention(g, ["victim"], "org1")
    assert count_mentions(admin, "g") == 1

    assert {:ok, _} = unmention(g, ["victim"], "org2")
    assert count_mentions(admin, "g") == 0
  end

  defp error_message(error) do
    case error do
      %{errors: errors} -> Enum.map_join(errors, " | ", &Exception.message/1)
      _ -> Exception.message(error)
    end
  end

  defp create_global(id) do
    EdgeGlobalPerson
    |> Ash.Changeset.for_create(:create, %{id: id, name: id})
    |> Ash.create()
  end

  defp mention(record, to, tenant) do
    record
    |> Ash.Changeset.for_update(:mention, %{to: to}, tenant: tenant)
    |> Ash.update()
  end

  defp unmention(record, to, tenant) do
    record
    |> Ash.Changeset.for_update(:unmention, %{to: to}, tenant: tenant)
    |> Ash.update()
  end
end
