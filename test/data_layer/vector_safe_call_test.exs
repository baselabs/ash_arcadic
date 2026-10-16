defmodule AshArcadic.DataLayer.VectorSafeCallTest do
  @moduledoc """
  DB-free coverage of `safe_vector_call` — the redaction backstop around the arcadic
  vector calls. Both failure classes under test fire BEFORE any network attempt, so the
  unreachable MockClient URL is never contacted:

  - arcadic's client-side argument validators (`require_pos_int!`/`require_list!`/
    `require_number!`/the `fusion` `enum!`) still raise value-free `ArgumentError`s on a
    CRAFTED stash (public `set_context`) whose shape passes the malformed guard but whose
    VALUES are bad (a non-number vector element, a bad `k`). The rescue converts the raise
    into a value-free `{:error, _}` instead of an uncaught crash across the callback
    boundary.
  - arcadic >= 1.2 returns a TYPED value-free `{:error, %Arcadic.Error{reason:
    :invalid_params}}` when a param value fails JSON encoding (arcadic 1.1 raised
    `Jason.EncodeError` with the offending bytes in the message). The reachable case: a
    fulltext fuse arm's `text_query` is shape-guarded `is_binary` only, so a non-UTF8
    binary passes the malformed guard and rides the `:q` param to the encoder.
  """
  use ExUnit.Case, async: true

  alias AshArcadic.Errors.QueryFailed
  alias AshArcadic.Test.VectorMockDoc

  @dense %{
    kind: :dense,
    index: :embedding,
    query_vector: [1.0, 0.0, 0.0],
    k: 3,
    allow_global?: false,
    opts: []
  }

  # A hybrid stash whose fulltext arm carries a valid-shaped but non-UTF8 binary text_query.
  @hybrid_poison_text %{
    kind: :hybrid,
    arms: [
      %{kind: :dense, property: :embedding, query_vector: [1.0, 0.0, 0.0], k: 3},
      %{
        kind: :fulltext,
        property: :name,
        text_query: <<0xFF, 0x00, 0x42>>,
        k: 3
      }
    ],
    allow_global?: false,
    opts: [fusion: :rrf]
  }

  defp vquery(vector_search) do
    struct(%AshArcadic.Query{
      resource: VectorMockDoc,
      label: "VectorMockDoc",
      tenant: nil,
      filters: [],
      vector_search: vector_search
    })
  end

  defp run(vector_search),
    do: AshArcadic.DataLayer.run_query(vquery(vector_search), VectorMockDoc)

  defp message({:error, err}), do: Exception.message(err)

  describe "client-side validator raises (ArgumentError rescued, value-free)" do
    test "a non-number element in a crafted query_vector fails closed, never crashes" do
      assert {:error, %QueryFailed{} = err} = run(%{@dense | query_vector: [:not_a_number]})
      assert message({:error, err}) =~ "vector search failed"
      # value-free: the crafted element never appears in the error
      refute message({:error, err}) =~ "not_a_number"
    end
  end

  describe "unencodable param values (arcadic >= 1.2 typed error, value-free)" do
    test "a non-UTF8 binary text_query surfaces the typed :invalid_params, value-free" do
      assert {:error, %QueryFailed{} = err} = run(@hybrid_poison_text)

      # The typed reason — NOT the generic rescue string. This discriminates the arcadic
      # 1.2 contract: on arcadic 1.1 the encoder raised Jason.EncodeError and the rescue
      # arm answered "vector search failed" instead.
      assert message({:error, err}) =~ "invalid_params"

      # value-free: the sentinel bytes (0xFF renders as 255) never appear in the error
      msg = message({:error, err})
      refute msg =~ "255"
      refute msg =~ "0xFF"
    end
  end
end
