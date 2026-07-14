defmodule AshArcadic.DataLayer.VectorSearchTest do
  @moduledoc """
  DB-free unit coverage of the vector dispatch head's fail-closed decisions. The scoped/global
  EXECUTION paths (candidate-set, self-injection, neighbors) are proven live in the integration
  suite (mutation-proven); here we cover every path that SHORT-CIRCUITS before any conn/DB access:
  the reject guards and the `:tenant_required` scope decision.
  """
  use ExUnit.Case, async: true
  alias AshArcadic.Test.VectorDoc

  @dense %{
    kind: :dense,
    index: :embedding,
    query_vector: [1.0, 0.0, 0.0],
    k: 3,
    allow_global?: false,
    opts: []
  }

  defp vquery(overrides) do
    struct(
      %AshArcadic.Query{
        resource: VectorDoc,
        label: "VectorDoc",
        tenant: "org_a",
        filters: [],
        vector_search: @dense
      },
      overrides
    )
  end

  defp run(query), do: AshArcadic.DataLayer.run_query(query, VectorDoc)
  defp message({:error, err}), do: Exception.message(err)

  describe "fail-closed reject guards (short-circuit before any DB access)" do
    test "a combination + vector_search fails closed (never silently one-or-the-other)" do
      result = run(vquery(combination_of: [{:union, %AshArcadic.Query{}}]))
      assert {:error, _} = result
      assert message(result) =~ "combination"
    end

    test "a non-dense kind fails closed (Plan-2 seam)" do
      result = run(vquery(vector_search: %{@dense | kind: :sparse}))
      assert {:error, _} = result
      assert message(result) =~ "dense"
    end

    test "aggregates over a vector search fail closed" do
      result = run(vquery(aggregates: [%{kind: :count}]))
      assert {:error, _} = result
      assert message(result) =~ "aggregate"
    end

    test "calculations over a vector search fail closed" do
      result = run(vquery(calculations: [:dummy]))
      assert {:error, _} = result
      assert message(result) =~ "calculation"
    end

    test "a set limit fails closed" do
      result = run(vquery(limit: 5))
      assert {:error, _} = result
      assert message(result) =~ "limit"
    end

    test "a non-zero offset fails closed" do
      assert {:error, _} = run(vquery(offset: 3))
    end
  end

  describe "scope decision (fail-closed short-circuits)" do
    test ":attribute + no tenant + allow_global? false fails closed with :tenant_required" do
      result = run(vquery(tenant: nil))
      assert {:error, _} = result
      assert message(result) =~ "tenant required"
    end

    test "spurious offset: 0 is treated as unset (does NOT trigger the paging reject)" do
      # offset 0 passes the paging guard, so the read reaches scope_mode; on the no-tenant path it
      # then fails at :tenant_required — proving offset 0 did NOT reject on paging grounds.
      result = run(vquery(tenant: nil, offset: 0))
      assert {:error, _} = result
      assert message(result) =~ "tenant required"
      refute message(result) =~ "limit/offset"
    end
  end

  describe "malformed stash guard (CV-2/CV-3 — the stash is public via set_context)" do
    test "a stash missing a required key fails closed" do
      malformed = %{kind: :dense, k: 3, allow_global?: false, opts: []}
      result = run(vquery(vector_search: malformed))
      assert {:error, _} = result
      assert message(result) =~ "malformed"
    end

    test "a non-boolean allow_global? is rejected — cannot open a global kNN" do
      # A hand-crafted truthy non-boolean must NOT resolve to :global (CV-2).
      malformed = %{
        kind: :dense,
        index: :embedding,
        query_vector: [1.0, 0.0, 0.0],
        k: 3,
        allow_global?: "false",
        opts: []
      }

      result = run(vquery(tenant: nil, vector_search: malformed))
      assert {:error, _} = result
      assert message(result) =~ "malformed"
    end

    test "the malformed error is value-free (never echoes the query vector)" do
      malformed = %{kind: :dense, k: 3, allow_global?: false, opts: [], query_vector: [31_337.5]}
      result = run(vquery(vector_search: malformed))
      assert {:error, _} = result
      refute message(result) =~ "31337"
      refute message(result) =~ "31_337"
    end
  end
end
