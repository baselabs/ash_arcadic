defmodule AshArcadic.Integration.BulkCreateTest do
  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.CrudPerson

  test "bulk_create inserts every changeset and returns stamped records" do
    result =
      Ash.bulk_create(
        [%{id: "b1", name: "X"}, %{id: "b2", name: "Y"}, %{id: "b3", name: "Z"}],
        CrudPerson,
        :create,
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :success
    assert length(result.records) == 3
    assert Enum.map(result.records, & &1.name) |> Enum.sort() == ["X", "Y", "Z"]

    {:ok, all} = CrudPerson |> Ash.Query.new() |> Ash.read()
    assert length(all) == 3
  end

  test "an empty batch is a no-op" do
    result = Ash.bulk_create([], CrudPerson, :create, return_records?: true)
    assert result.status == :success
    assert result.records in [[], nil]
  end
end
