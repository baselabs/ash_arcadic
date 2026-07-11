defmodule AshArcadic.Integration.ReservedKeyTest do
  @moduledoc """
  A resource whose primary key / attribute is literally named `:set` or `:all` must not
  collide with the bulk-write row-map container keys. The bulk `UNWIND $rows` paths carry
  identity/PK values TOP-LEVEL (P4/P5: only top-level `r.<pk>` node-pattern access is proven)
  alongside the container maps — so the containers are namespaced to leading-underscore keys
  (`Arcadic.Identifier` requires a leading letter, so a namespaced key can never equal a field
  name that reaches the Cypher).
  """
  use AshArcadic.Test.IntegrationCase

  alias AshArcadic.Test.ReservedKeyDoc, as: R

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:ReservedKeyDoc) DETACH DELETE n") end)
    :ok
  end

  test "bulk upsert resolves a resource whose PK is named :set (existing→update, new→create)" do
    R
    |> Ash.Changeset.for_create(:create, %{set: "a", name: "old-a", all: "keepA"})
    |> Ash.create!()

    %Ash.BulkResult{status: :success} =
      Ash.bulk_create(
        [%{set: "a", name: "new-a", all: "keepA"}, %{set: "b", name: "new-b", all: "keepB"}],
        R,
        :upsert,
        upsert?: true,
        upsert_fields: [:name],
        return_records?: true
      )

    rows = Ash.read!(R)
    # No duplicate: "a" updated in place, "b" created. Without namespacing, r.set would carry the
    # container map (not "a"), so the MERGE never matches and the count would be wrong.
    assert length(rows) == 2
    assert Map.new(rows, &{&1.set, &1.name}) == %{"a" => "new-a", "b" => "new-b"}
    # The `:all` attribute (nested in the property map) round-trips too.
    assert Ash.get!(R, "a").all == "keepA"
  end

  test "update_many resolves a resource whose PK is named :set" do
    R |> Ash.Changeset.for_create(:create, %{set: "u", name: "orig"}) |> Ash.create!()
    rec = Ash.get!(R, "u")

    Ash.update_many([{rec, %{name: "changed"}}], R, :update,
      strategy: :atomic,
      return_records?: true
    )

    # Without namespacing, r.set carries the container map → MATCH misses → the update no-ops.
    assert Ash.get!(R, "u").name == "changed"
  end
end
