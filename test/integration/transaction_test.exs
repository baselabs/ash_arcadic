defmodule AshArcadic.Integration.TransactionTest do
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Test.CrudPerson

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:CrudPerson) DETACH DELETE n") end)
    %{admin: admin}
  end

  # Builds and runs the data-layer create for `id`/`name`; returns DL.create's result.
  defp create_person(id, name) do
    CrudPerson
    |> Ash.Changeset.for_create(:create, %{id: id, name: name})
    |> then(&DL.create(CrudPerson, &1))
  end

  # Sorted ids currently persisted, read via the non-session admin conn (committed state).
  defp ids(admin) do
    admin
    |> Arcadic.command!("MATCH (n:CrudPerson) RETURN n.id AS id")
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  test "commit persists every write in the transaction", %{admin: admin} do
    assert {:ok, :done} =
             DL.transaction(CrudPerson, fn ->
               {:ok, _} = create_person("c1", "A")
               {:ok, _} = create_person("c2", "B")
               :done
             end)

    assert ids(admin) == ["c1", "c2"]
  end

  test "rollback discards every write in the transaction", %{admin: admin} do
    assert {:error, :abort} =
             DL.transaction(CrudPerson, fn ->
               {:ok, _} = create_person("r1", "A")
               {:ok, _} = create_person("r2", "B")
               DL.rollback(CrudPerson, :abort)
             end)

    assert ids(admin) == []
  end

  # CV3 residual closure: a duplicate-PK update matches 2 rows → UpdateFailed; inside a
  # transaction the multi-SET rolls back. Non-vacuous: both rows keep name "orig", NOT
  # "changed" — proving the mutate-then-error write was discarded (the Plan-2 residual).
  test "a multi-row update inside a transaction rolls the multi-SET back (CV3)", %{admin: admin} do
    for _ <- 1..2, do: Arcadic.command!(admin, "CREATE (n:CrudPerson {id:'dup', name:'orig'})")
    {:ok, [record | _]} = Ash.read(CrudPerson)

    result =
      DL.transaction(CrudPerson, fn ->
        changeset = Ash.Changeset.for_update(record, :update, %{name: "changed"})

        case DL.update(CrudPerson, changeset) do
          {:error, _} = err -> DL.rollback(CrudPerson, err)
          other -> other
        end
      end)

    assert match?({:error, {:error, %AshArcadic.Errors.UpdateFailed{}}}, result)

    names =
      admin
      |> Arcadic.command!("MATCH (n:CrudPerson {id:'dup'}) RETURN n.name AS name")
      |> Enum.map(& &1["name"])

    assert names == ["orig", "orig"]
  end

  test "a stale (no-match) update inside a transaction fails closed as StaleRecord", %{
    admin: admin
  } do
    {:ok, record} = create_person("s1", "A")
    Arcadic.command!(admin, "MATCH (n:CrudPerson {id:$id}) DETACH DELETE n", %{"id" => "s1"})

    result =
      DL.transaction(CrudPerson, fn ->
        changeset = Ash.Changeset.for_update(record, :update, %{name: "y"})
        DL.update(CrudPerson, changeset)
      end)

    assert {:ok, {:error, %Ash.Error.Changes.StaleRecord{}}} = result
  end

  test "in_transaction?/1 is true inside the fun and false outside" do
    refute DL.in_transaction?(CrudPerson)
    {:ok, inside?} = DL.transaction(CrudPerson, fn -> DL.in_transaction?(CrudPerson) end)
    assert inside?
    refute DL.in_transaction?(CrudPerson)
  end
end
