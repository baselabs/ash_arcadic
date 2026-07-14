defmodule AshArcadic.Integration.VectorSearchContextTest do
  @moduledoc """
  F1 coverage: the `:context` (database-per-tenant) vector scope branch. Each tenant is a physical
  DB, so isolation is physical — a scoped search runs in the tenant DB and cannot see another
  tenant's rows. Proves the `:context` branch of vector_scope_mode + run_vector_search, and the
  blank-tenant fail-closed.
  """
  use AshArcadic.Test.IntegrationCase
  alias AshArcadic.Multitenancy
  alias AshArcadic.Test.VectorContextDoc

  @qv [1.0, 0.0, 0.0]

  setup %{admin: admin} do
    ta = "vec_ctx_a_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    tb = "vec_ctx_b_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    seed = fn tenant, rows ->
      db = Multitenancy.database_name(VectorContextDoc, tenant)
      :ok = Arcadic.Server.create_database!(admin, db)
      conn = Arcadic.with_database(admin, db)
      cmd = fn s -> Arcadic.command!(conn, s, %{}, language: "sql") end
      cmd.("CREATE VERTEX TYPE VectorContextDoc")
      cmd.("CREATE PROPERTY VectorContextDoc.id STRING")
      cmd.("CREATE PROPERTY VectorContextDoc.name STRING")
      cmd.("CREATE PROPERTY VectorContextDoc.embedding ARRAY_OF_FLOATS")

      for {id, emb} <- rows,
          do: cmd.("INSERT INTO VectorContextDoc SET id='#{id}', name='#{id}', embedding=#{emb}")

      Arcadic.Vector.create_dense_index!(conn, "VectorContextDoc", "embedding", 3,
        similarity: :cosine
      )

      db
    end

    # tenant b's rows are ON the query vector — if a's search could see them they'd rank first.
    db_a = seed.(ta, [{"a1", "[0.9,0.1,0.0]"}, {"a2", "[0.0,1.0,0.0]"}])
    db_b = seed.(tb, [{"b1", "[1.0,0.0,0.0]"}, {"b2", "[0.99,0.01,0.0]"}])

    on_exit(fn ->
      Arcadic.Server.drop_database(admin, db_a)
      Arcadic.Server.drop_database(admin, db_b)
    end)

    {:ok, ta: ta, tb: tb}
  end

  test "T-e :context scoped returns ONLY the tenant's rows (physical isolation) + distance", %{
    ta: ta
  } do
    {:ok, rows} =
      VectorContextDoc
      |> Ash.Query.for_read(:semantic_search, %{query_vector: @qv, k: 5})
      |> Ash.Query.set_tenant(ta)
      |> Ash.read(authorize?: false)

    names = rows |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["a1", "a2"], "context leak: #{inspect(names)}"
    refute Enum.any?(rows, &(&1.name in ["b1", "b2"]))
    assert Enum.all?(rows, &is_number(&1.__metadata__[:vector_distance]))
  end

  test "T-e :context with a blank tenant fails closed (tenant required)" do
    result =
      VectorContextDoc
      |> Ash.Query.for_read(:semantic_search, %{query_vector: @qv, k: 3})
      |> Ash.read(authorize?: false)

    assert {:error, _} = result
  end
end
