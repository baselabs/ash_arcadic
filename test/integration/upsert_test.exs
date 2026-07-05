defmodule AshArcadic.Integration.UpsertTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.{UpsertComposite, UpsertThing}

  defp upsert(resource, attrs),
    do: resource |> Ash.Changeset.for_create(:upsert, attrs) |> Ash.create()

  test "first upsert creates; replay on the same identity MATCHES one node, updating on-match fields" do
    {:ok, a} = upsert(UpsertThing, %{code: "x", name: "First"})
    assert a.name == "First"

    {:ok, b} = upsert(UpsertThing, %{code: "x", name: "Second"})
    assert b.name == "Second"

    {:ok, all} = UpsertThing |> Ash.Query.filter(code == "x") |> Ash.read()
    assert length(all) == 1
  end

  test "composite identity: same (region,code) matches; a differing member creates" do
    {:ok, _} = upsert(UpsertComposite, %{region: "us", code: "x", name: "A"})
    {:ok, _} = upsert(UpsertComposite, %{region: "us", code: "x", name: "B"})
    {:ok, _} = upsert(UpsertComposite, %{region: "eu", code: "x", name: "C"})

    {:ok, all} = UpsertComposite |> Ash.Query.new() |> Ash.read()
    assert length(all) == 2
    assert Enum.find(all, &(&1.region == "us")).name == "B"
  end
end
