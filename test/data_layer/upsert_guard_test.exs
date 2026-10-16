defmodule AshArcadic.DataLayer.UpsertGuardTest do
  use ExUnit.Case, async: true

  test "upsert fails closed on an empty identity (never MERGE (n:L {}) matching any node)" do
    changeset = Ash.Changeset.for_create(AshArcadic.Test.CrudPerson, :create, %{id: "z"})

    assert {:error, %AshArcadic.Errors.CreateFailed{} = err} =
             AshArcadic.DataLayer.upsert(AshArcadic.Test.CrudPerson, changeset, [])

    # The struct match alone is vacuous (the bulk sibling documents why): a transport
    # failure also surfaces as CreateFailed. Assert the guard's own REASON string.
    assert err.reason =~ "non-empty identity"
  end
end
