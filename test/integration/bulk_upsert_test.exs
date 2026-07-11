defmodule AshArcadic.Integration.BulkUpsertTest do
  @moduledoc false
  use AshArcadic.Test.IntegrationCase

  # UpsertThing (test/support/resources/upsert_thing.ex): non-multitenant, PK :code, a `:upsert`
  # action (`upsert? true`, no explicit identity → upserts on the PK :code). Ash requires
  # `upsert_fields` for a BULK upsert (deps/ash actions/create/bulk.ex:126).
  alias AshArcadic.Test.UpsertThing

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:UpsertThing) DETACH DELETE n") end)
    :ok
  end

  test "multi-row bulk upsert: existing rows update, new rows create, one statement" do
    UpsertThing |> Ash.Changeset.for_create(:create, %{code: "a", name: "old-a"}) |> Ash.create!()
    UpsertThing |> Ash.Changeset.for_create(:create, %{code: "b", name: "old-b"}) |> Ash.create!()

    inputs = [
      %{code: "a", name: "new-a"},
      %{code: "b", name: "new-b"},
      %{code: "z", name: "new-z"}
    ]

    %Ash.BulkResult{status: :success} =
      Ash.bulk_create(inputs, UpsertThing, :upsert,
        upsert?: true,
        upsert_fields: [:name],
        return_records?: true
      )

    all = UpsertThing |> Ash.read!() |> Map.new(&{&1.code, &1.name})
    assert all == %{"a" => "new-a", "b" => "new-b", "z" => "new-z"}
  end

  test "bulk upsert is idempotent (re-run yields the same rows, no duplicates)" do
    inputs = [%{code: "x", name: "one"}]
    opts = [upsert?: true, upsert_fields: [:name]]

    Ash.bulk_create(inputs, UpsertThing, :upsert, opts)
    Ash.bulk_create(inputs, UpsertThing, :upsert, opts)

    xs = UpsertThing |> Ash.read!() |> Enum.filter(&(&1.code == "x"))
    assert length(xs) == 1
  end
end
