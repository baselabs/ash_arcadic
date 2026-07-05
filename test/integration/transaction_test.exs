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

  # F4 (probe-verified 2026-07-05, live ArcadeDB): a commit that fails with an MVCC
  # ConcurrentModificationException (HTTP 503 "Please retry") surfaces through the real DL
  # stack as {:error, :transaction_commit_failed}; run/1 rolls the still-open session back so
  # it does not leak. Forced deterministically: stage an in-session update (captures the row
  # version), then bump the SAME row via the admin conn (autocommit) before the fun returns —
  # run/1's commit then conflicts on the stale version.
  test "an MVCC conflict at commit surfaces :transaction_commit_failed; session write discarded",
       %{admin: admin} do
    {:ok, _} = create_person("mvcc", "orig")
    {:ok, [record | _]} = Ash.read(CrudPerson)

    result =
      DL.transaction(CrudPerson, fn ->
        changeset = Ash.Changeset.for_update(record, :update, %{name: "session-change"})
        {:ok, _} = DL.update(CrudPerson, changeset)

        # OUTSIDE the session (admin autocommit): bump the same row → sets up the commit conflict.
        Arcadic.command!(admin, "MATCH (n:CrudPerson {id:'mvcc'}) SET n.name='concurrent'")
        :staged
      end)

    assert result == {:error, :transaction_commit_failed}

    names =
      admin
      |> Arcadic.command!("MATCH (n:CrudPerson {id:'mvcc'}) RETURN n.name AS name")
      |> Enum.map(& &1["name"])

    # the concurrent (committed) write persisted; the session's staged write was discarded.
    assert names == ["concurrent"]
  end

  describe "per-op spans carry in_transaction?" do
    test "a create reports in_transaction? false outside and true inside a transaction" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:ash_arcadic, :create, :stop]])
      on_exit(fn -> :telemetry.detach(ref) end)

      {:ok, _} = create_person("io-out", "A")
      assert_received {[:ash_arcadic, :create, :stop], ^ref, _measure, %{in_transaction?: false}}

      {:ok, :ok} =
        DL.transaction(CrudPerson, fn ->
          {:ok, _} = create_person("io-in", "B")
          :ok
        end)

      assert_received {[:ash_arcadic, :create, :stop], ^ref, _measure, %{in_transaction?: true}}
    end
  end
end
