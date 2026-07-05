defmodule AshArcadic.Integration.DestroyEdgeTest do
  use AshArcadic.Test.IntegrationCase
  alias AshArcadic.Test.EdgeDestroyPerson

  defp count_edges(admin, from_id, label) do
    {:ok, [%{"c" => c}]} =
      Arcadic.query(admin, "MATCH (a:EDPerson {id:$id})-[e:#{label}]->() RETURN count(e) AS c", %{
        "id" => from_id
      })

    c
  end

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:EDPerson) DETACH DELETE n") end)
    :ok
  end

  test "unfriend removes an existing edge", %{admin: admin} do
    {:ok, a} = create_person("a", "org1")
    {:ok, _} = create_person("b", "org1")
    {:ok, _} = befriend(a, ["b"], "org1")

    assert {:ok, _} = unfriend(a, ["b"], "org1")

    assert count_edges(admin, "a", "KNOWS") == 0
  end

  test "unfriend of an absent edge fails closed as StaleRecord", %{} do
    {:ok, a} = create_person("a", "org1")
    {:ok, _} = create_person("b", "org1")
    # no edge exists
    assert {:error, %Ash.Error.Invalid{errors: errors}} = unfriend(a, ["b"], "org1")
    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  test "cross-tenant unfriend is denied (StaleRecord — wrong tenant can't delete)", %{
    admin: admin
  } do
    {:ok, a1} = create_person("a", "org1")
    {:ok, _} = create_person("b", "org1")
    {:ok, _} = befriend(a1, ["b"], "org1")

    # org2 actor with the same source id must not delete org1's edge.
    {:ok, a2} = create_person("a", "org2")
    assert {:error, %Ash.Error.Invalid{errors: errors}} = unfriend(a2, ["b"], "org2")
    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

    # org1's edge must SURVIVE the denied cross-tenant delete
    {:ok, [%{"c" => c}]} =
      Arcadic.query(
        admin,
        "MATCH (:EDPerson {id:'a', tenant:'org1'})-[e:KNOWS]->() RETURN count(e) AS c",
        %{}
      )

    assert c == 1
  end

  test "unfriend with a non-JSON-encodable destination id fails closed value-free (encode-gate, Rule 4)",
       %{} do
    {:ok, a} = create_person("a", "org1")

    # A raw non-UTF8 binary id survives Ash's :string cast, but Jason.encode raises
    # with the bytes in the message. The full-param encode-gate must catch it BEFORE
    # the transport (spec §6.3 — the gate runs before EVERY edge command), so the
    # error is a value-free InvalidRelationship naming only the key, NOT a raised
    # Jason.EncodeError carrying the raw bytes.
    poisoned = <<0xFF, 0xFE>>

    result =
      try do
        unfriend(a, [poisoned], "org1")
      rescue
        e -> {:raised, e}
      end

    assert {:error, %Ash.Error.Invalid{errors: errors}} = result
    assert Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidRelationship{}, &1))
    # value-free: neither the raw bytes nor their byte representation reach the message
    message = Exception.message(%Ash.Error.Invalid{errors: errors})
    refute message =~ poisoned
    refute message =~ "255"
    refute message =~ "0xFF"
  end

  test "a :both edge is deletable from the OTHER endpoint (either orientation, spec §6.2)", %{
    admin: admin
  } do
    {:ok, a} = create_person("a", "org1")
    {:ok, b} = create_person("b", "org1")
    # A befriends B → a :both edge is written outgoing as (a)-[PALS]->(b) (§6.1).
    {:ok, _} = befriend_pals(a, ["b"], "org1")

    # B unfriends A. The edge is INCOMING from B's perspective; an outgoing-only
    # DELETE would miss it. Undirected `:both` match must remove it.
    assert {:ok, _} = unfriend_pals(b, ["a"], "org1")

    {:ok, [%{"c" => c}]} =
      Arcadic.query(admin, "MATCH (:EDPerson)-[e:PALS]-(:EDPerson) RETURN count(e) AS c", %{})

    assert c == 0
  end

  test "cross-tenant :both unfriend is denied — undirected match still scopes BOTH endpoints", %{
    admin: admin
  } do
    {:ok, a1} = create_person("a", "org1")
    {:ok, _} = create_person("b", "org1")
    {:ok, _} = befriend_pals(a1, ["b"], "org1")

    # org2 actor with the same src id must NOT delete org1's :both PALS edge. The match
    # is undirected, but the WHERE still pins BOTH endpoints to org2 — dropping either
    # tenant clause would let this delete org1's edge (the over-delete fence).
    {:ok, a2} = create_person("a", "org2")
    assert {:error, %Ash.Error.Invalid{errors: errors}} = unfriend_pals(a2, ["b"], "org2")
    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

    # org1's PALS edge SURVIVES the denied cross-tenant delete
    {:ok, [%{"c" => c}]} =
      Arcadic.query(
        admin,
        "MATCH (:EDPerson {id:'a', tenant:'org1'})-[e:PALS]-(:EDPerson {id:'b', tenant:'org1'}) RETURN count(e) AS c",
        %{}
      )

    assert c == 1
  end

  defp create_person(id, tenant) do
    EdgeDestroyPerson
    |> Ash.Changeset.for_create(:create, %{id: id, name: id, tenant: tenant}, tenant: tenant)
    |> Ash.create()
  end

  defp befriend_pals(actor, to, tenant) do
    actor
    |> Ash.Changeset.for_update(:befriend_pals, %{to: to}, tenant: tenant)
    |> Ash.update()
  end

  defp unfriend_pals(actor, to, tenant) do
    actor
    |> Ash.Changeset.for_update(:unfriend_pals, %{to: to}, tenant: tenant)
    |> Ash.update()
  end

  defp befriend(actor, to, tenant) do
    actor
    |> Ash.Changeset.for_update(:befriend, %{to: to}, tenant: tenant)
    |> Ash.update()
  end

  defp unfriend(actor, to, tenant) do
    actor
    |> Ash.Changeset.for_update(:unfriend, %{to: to}, tenant: tenant)
    |> Ash.update()
  end
end
