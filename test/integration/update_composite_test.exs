defmodule AshArcadic.Integration.UpdateCompositeTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.UpsertComposite

  # Composite-PK update exercises pk_match_clause/1's multi-field AND WHERE
  # (`n.region = $match_region AND n.code = $match_code`) end-to-end — the single-PK
  # update tests never reach the 2+-field join. Closes the Task-12 deferred coverage.
  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:UpsertComposite) DETACH DELETE n") end)
    :ok
  end

  defp create(attrs),
    do: UpsertComposite |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!()

  # NON-VACUITY (against dropping EITHER pk field): the target (us, x) shares its
  # FIRST field with (us, y) and its SECOND field with (eu, x). A correct composite
  # WHERE matches EXACTLY (us, x). A WHERE that dropped `code` (region-only) matches
  # {(us,x),(us,y)} → 2 rows → UpdateFailed; one that dropped `region` (code-only)
  # matches {(us,x),(eu,x)} → 2 rows → UpdateFailed. Either mutation turns the
  # `{:ok, updated}` assertion RED (verified by mutation-and-revert at review time).
  test "update matches on the FULL composite PK (region AND code), not either field alone" do
    us_x = create(%{region: "us", code: "x", name: "A"})
    _us_y = create(%{region: "us", code: "y", name: "B"})
    _eu_x = create(%{region: "eu", code: "x", name: "C"})

    {:ok, updated} = us_x |> Ash.Changeset.for_update(:update, %{name: "A2"}) |> Ash.update()
    assert updated.name == "A2"

    {:ok, all} = UpsertComposite |> Ash.Query.for_read(:read) |> Ash.read()
    by_key = Map.new(all, &{{&1.region, &1.code}, &1.name})

    assert by_key == %{
             {"us", "x"} => "A2",
             {"us", "y"} => "B",
             {"eu", "x"} => "C"
           }
  end

  test "update on a composite PK that matches no row fails closed as StaleRecord" do
    ghost = struct(UpsertComposite, region: "us", code: "gone", name: "X")

    assert {:error, error} =
             ghost |> Ash.Changeset.for_update(:update, %{name: "Y"}) |> Ash.update()

    assert Enum.any?(List.wrap(error.errors), &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end
end
