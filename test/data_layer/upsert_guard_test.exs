defmodule AshArcadic.DataLayer.UpsertGuardTest do
  use ExUnit.Case, async: true

  test "upsert fails closed on an empty identity (never MERGE (n:L {}) matching any node)" do
    changeset = Ash.Changeset.for_create(AshArcadic.Test.CrudPerson, :create, %{id: "z"})

    assert {:error, %AshArcadic.Errors.CreateFailed{}} =
             AshArcadic.DataLayer.upsert(AshArcadic.Test.CrudPerson, changeset, [])
  end
end
