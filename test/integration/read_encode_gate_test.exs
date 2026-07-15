defmodule AshArcadic.Integration.ReadEncodeGateTest do
  @moduledoc """
  Slice 11 Workstream 2 (adversarial F2): a non-UTF8 binary nested in a READ filter literal reaches
  the wire ungated, where Req/Jason raises `Jason.EncodeError` with the offending bytes in its message
  — a value leak (AGENTS.md Rule 4). `read_encode_gate/1` catches it value-free before EVERY read
  `Arcadic.query(conn, cypher, params)` site: flat (data_layer.ex do_run_query), aggregate/count
  (run_aggregate_statement), combination (run_native_combination / run_branch), traversal
  (traverse.ex). The message names the failure CLASS, never a value.

  Poison: a raw non-UTF8 binary NESTED in a `:map` value (top-level binaries are base64'd by
  serialize_value; nested ones are not). The sentinel 0xFF renders as "255" / "0xFF" in a Jason raise.
  """
  use AshArcadic.Test.IntegrationCase
  require Ash.Query
  require Ash.Expr

  alias Ash.Query.Combination
  alias AshArcadic.Test.{ReadEncodeDoc, TraverseAttrNode, VectorDoc}

  @poison %{"k" => <<0xFF, 0x00, 0x42>>}

  setup %{admin: admin} do
    on_exit(fn -> Arcadic.command!(admin, "MATCH (n:ReadEncodeDoc) DETACH DELETE n") end)
    :ok
  end

  # Run `fun` and return the error message, whether the poison was caught as {:error} (gated) or
  # crossed the boundary as a raised Jason.EncodeError (ungated). flunk if the read SUCCEEDS.
  defp read_error_message(fun) do
    case fun.() do
      {:error, error} -> Exception.message(error)
      {:ok, _} -> flunk("expected the poisoned read to fail, but it succeeded")
      other -> flunk("unexpected read result: #{inspect(other)}")
    end
  rescue
    error -> Exception.message(error)
  end

  # A value-free error names the failure class and NEVER the poison bytes (0xFF → "255"/"0xFF").
  defp assert_value_free(msg) do
    refute msg =~ "255", "message leaked the poison byte 0xFF (rendered 255): #{msg}"
    refute msg =~ "0xFF", "message leaked the poison byte 0xFF: #{msg}"

    assert msg =~ "not JSON-encodable",
           "expected the value-free read-encode-gate reason, got: #{msg}"
  end

  test "flat read: a poisoned :map filter fails closed value-free (do_run_query)" do
    msg =
      read_error_message(fn ->
        ReadEncodeDoc |> Ash.Query.filter(data == ^@poison) |> Ash.read(tenant: "org1")
      end)

    assert_value_free(msg)
  end

  test "aggregate/count: a poisoned :map filter fails closed value-free (run_aggregate_statement)" do
    msg =
      read_error_message(fn ->
        ReadEncodeDoc |> Ash.Query.filter(data == ^@poison) |> Ash.count(tenant: "org1")
      end)

    assert_value_free(msg)
  end

  test "combination: a poisoned :map filter in a branch fails closed value-free (run_combination)" do
    poison = @poison

    msg =
      read_error_message(fn ->
        ReadEncodeDoc
        |> Ash.Query.for_read(:read)
        |> Ash.Query.combination_of([
          Combination.base(filter: Ash.Expr.expr(data == ^poison)),
          Combination.union(filter: Ash.Expr.expr(id == "never"))
        ])
        |> Ash.read(tenant: "org1")
      end)

    assert_value_free(msg)
  end

  test "in-memory combination branch: a poisoned :map filter fails closed value-free (run_branch, paged)" do
    # A PAGED combination routes to the in-memory path (run_inmemory_combination -> run_branch), a
    # DISTINCT gated wire site from the native combination above (gate-integrity F-info). The poison
    # rides the branch's to_cypher params.
    poison = @poison

    msg =
      read_error_message(fn ->
        ReadEncodeDoc
        |> Ash.Query.for_read(:read)
        |> Ash.Query.combination_of([
          Combination.base(filter: Ash.Expr.expr(data == ^poison)),
          Combination.union(filter: Ash.Expr.expr(id == "never"))
        ])
        |> Ash.read(tenant: "org1", page: [limit: 1])
      end)

    assert_value_free(msg)
  end

  test "keyset page: a poisoned :map filter on a keyset-paginated read fails closed value-free" do
    # A keyset page routes through do_run_query (same gate as the flat read); the poison rides the
    # cursor/filter params. Also covers a CRAFTED cursor carrying a non-encodable value.
    msg =
      read_error_message(fn ->
        ReadEncodeDoc
        |> Ash.Query.filter(data == ^@poison)
        |> Ash.Query.sort(id: :asc)
        |> Ash.read(tenant: "org1", page: [limit: 2])
      end)

    assert_value_free(msg)
  end

  test "traversal: a non-encodable tenant fails closed value-free (traverse.ex read gate at :402)" do
    {:ok, p1} =
      TraverseAttrNode
      |> Ash.Changeset.for_create(:create, %{id: "p1", name: "P1"}, tenant: "org1")
      |> Ash.create()

    on_exit(fn ->
      admin =
        Arcadic.connect(
          System.get_env("ARCADIC_TEST_URL"),
          Application.get_env(:ash_arcadic, :integration_database),
          auth: {"root", System.get_env("ARCADIC_TEST_PASSWORD", "arcadedb_dev_password")}
        )

      Arcadic.command!(admin, "MATCH (n:TravAttrNode) DETACH DELETE n")
    end)

    # A non-UTF8 binary tenant reaches build_traverse's $tenant param; the read_encode_gate at
    # traverse.ex catches it value-free before the wire (the $ids are already gated at :383).
    msg = read_error_message(fn -> Ash.load(p1, :descendants, tenant: <<0xFF, 0x00, 0x42>>) end)

    assert_value_free(msg)
  end

  test "vector candidate: a poisoned :map filter on a vector search fails closed value-free (vector_candidate_search)" do
    on_exit(fn ->
      admin =
        Arcadic.connect(
          System.get_env("ARCADIC_TEST_URL"),
          Application.get_env(:ash_arcadic, :integration_database),
          auth: {"root", System.get_env("ARCADIC_TEST_PASSWORD", "arcadedb_dev_password")}
        )

      Arcadic.command!(admin, "MATCH (n:VectorDoc) DETACH DELETE n")
    end)

    # The caller filter (meta == poison) composes into candidate_rid_cypher's params (the same
    # self-injection path the vector isolation tests exercise); the read_encode_gate at
    # vector_candidate_search catches it value-free before the candidate query hits the wire.
    poison = @poison

    msg =
      read_error_message(fn ->
        VectorDoc
        |> Ash.Query.for_read(:semantic_search, %{query_vector: [1.0, 0.0, 0.0], k: 2})
        |> Ash.Query.filter(meta == ^poison)
        |> Ash.read(tenant: "org1", authorize?: false)
      end)

    assert_value_free(msg)
  end
end
