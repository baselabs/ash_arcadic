defmodule AshArcadic.Preparations.VectorSearch do
  @moduledoc """
  Read-action preparation that turns an Ash read into a vector search — **dense** kNN, **sparse**
  (learned-sparse / BM25-style) kNN, or **hybrid** fusion (dense/sparse/full-text arms). Attach it
  to a read action whose arguments carry the query data:

      # dense (default kind)
      read :semantic_search do
        argument :query_vector, {:array, :float}, allow_nil?: false
        argument :k, :integer, allow_nil?: false
        prepare {AshArcadic.Preparations.VectorSearch, index: :embedding}
      end

      # sparse
      read :sparse_search do
        argument :query_tokens, {:array, :integer}, allow_nil?: false
        argument :query_weights, {:array, :float}, allow_nil?: false
        argument :k, :integer, allow_nil?: false
        prepare {AshArcadic.Preparations.VectorSearch, kind: :sparse, index: :sparse_embedding}
      end

      # hybrid — arms name the indexes/properties (developer config); the caller passes the values
      read :hybrid_search do
        argument :query_vector, {:array, :float}, allow_nil?: false
        argument :query_tokens, {:array, :integer}, allow_nil?: false
        argument :query_weights, {:array, :float}, allow_nil?: false
        argument :text_query, :string, allow_nil?: false
        argument :k, :integer, allow_nil?: false
        prepare {AshArcadic.Preparations.VectorSearch,
                 kind: :hybrid,
                 arms: [{:dense, :embedding}, {:sparse, :sparse_embedding}, {:fulltext, :body}],
                 fusion: :rrf}
      end

  Options:

    * `:kind` (default `:dense`) — `:dense` | `:sparse` | `:hybrid`.
    * `:index` (required for `:dense`/`:sparse`, atom) — the declared `vector_index` /
      `sparse_vector_index` name.
    * `:arms` (required for `:hybrid`) — a list (len ≥ 2) of `{:dense, index}` | `{:sparse, index}`
      | `{:fulltext, property}`. The full-text arm's `property` is an attribute with a host-created
      full-text index (there is no full-text DSL declaration — that is a later slice); the caller
      passes the `:text_query` argument. `:fusion` (`:rrf` default | `:dbsf` | `:linear`),
      `:weights`, `:group_by`, `:group_size` ride the fused output. A single `:k` argument bounds
      every arm and the fused result.
    * `:allow_global?` (default `false`) — permit a cross-tenant search when no tenant is resolved.
      The Ash action must ALSO permit the no-tenant read (`multitenancy :allow_global`/`:bypass`),
      else Ash rejects it upstream with `TenantRequired`.
    * `:ef_search`, `:max_distance` — dense only (sparse/fuse reject them);
      `:group_by`, `:group_size` — sparse pass-through.

  It reads the query arguments, resolves the declared index metadata, validates a dense vector's
  length against the declared `dimensions`, and stashes the request onto the query context
  (`:vector_search`), which the data layer's `set_context/3` copies onto `%AshArcadic.Query{}`.
  All failures are value-free (never echo a vector / tokens / weights / text value).
  """
  use Ash.Resource.Preparation
  alias Ash.Error.Query.InvalidArgument
  alias AshArcadic.DataLayer.Info

  @dense_passthrough [:ef_search, :max_distance]
  # N1 (plan-review): sparse's arcadic opts allowlist is [:filter, :group_by, :group_size] — it
  # REJECTS ef_search/max_distance, so sparse must NOT reuse the dense passthrough.
  @sparse_passthrough [:group_by, :group_size]

  @impl true
  def init(opts) do
    case Keyword.get(opts, :kind, :dense) do
      kind when kind in [:dense, :sparse] ->
        validate_index_opt(opts)

      :hybrid ->
        validate_arms_opt(opts)

      other ->
        {:error,
         "AshArcadic.Preparations.VectorSearch :kind must be :dense, :sparse, or :hybrid " <>
           "(got #{inspect(other)})"}
    end
  end

  defp validate_index_opt(opts) do
    case Keyword.get(opts, :index) do
      index when is_atom(index) and not is_nil(index) ->
        {:ok, opts}

      _ ->
        {:error, "AshArcadic.Preparations.VectorSearch requires an `:index` (atom) option"}
    end
  end

  defp validate_arms_opt(opts) do
    arms = Keyword.get(opts, :arms)

    cond do
      not (is_list(arms) and length(arms) >= 2) ->
        {:error, "a :hybrid vector search requires an `:arms` list of at least 2 arms"}

      not Enum.all?(arms, &valid_arm_spec?/1) ->
        {:error,
         "each :arms entry must be {:dense, index} | {:sparse, index} | {:fulltext, property}"}

      true ->
        {:ok, opts}
    end
  end

  defp valid_arm_spec?({:dense, index}) when is_atom(index), do: true
  defp valid_arm_spec?({:sparse, index}) when is_atom(index), do: true
  defp valid_arm_spec?({:fulltext, property}) when is_atom(property), do: true
  defp valid_arm_spec?(_), do: false

  @impl true
  def prepare(query, opts, _context) do
    case Keyword.get(opts, :kind, :dense) do
      :dense -> prepare_dense(query, opts)
      :sparse -> prepare_sparse(query, opts)
      :hybrid -> prepare_hybrid(query, opts)
    end
  end

  defp prepare_dense(query, opts) do
    index_name = Keyword.fetch!(opts, :index)

    with {:ok, query_vector} <- fetch_list_arg(query, :query_vector),
         {:ok, k} <- fetch_k(query),
         {:ok, index} <- fetch_dense_index(query, index_name),
         :ok <- validate_dimensions(query_vector, index) do
      stash(query, %{
        kind: :dense,
        index: index_name,
        query_vector: query_vector,
        k: k,
        allow_global?: allow_global?(opts),
        opts: Keyword.take(opts, @dense_passthrough)
      })
    else
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  defp prepare_sparse(query, opts) do
    index_name = Keyword.fetch!(opts, :index)

    with {:ok, tokens} <- fetch_list_arg(query, :query_tokens),
         {:ok, weights} <- fetch_list_arg(query, :query_weights),
         {:ok, k} <- fetch_k(query),
         {:ok, index} <- fetch_sparse_index(query, index_name) do
      stash(query, %{
        kind: :sparse,
        index: index_name,
        tokens_property: index.tokens,
        weights_property: index.weights,
        query_tokens: tokens,
        query_weights: weights,
        k: k,
        allow_global?: allow_global?(opts),
        opts: Keyword.take(opts, @sparse_passthrough)
      })
    else
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  defp prepare_hybrid(query, opts) do
    arms = Keyword.fetch!(opts, :arms)

    with {:ok, k} <- fetch_k(query),
         {:ok, arm_maps} <- resolve_arms(query, arms, k) do
      stash(query, %{
        kind: :hybrid,
        arms: arm_maps,
        allow_global?: allow_global?(opts),
        opts: fuse_opts(opts, k)
      })
    else
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  defp resolve_arms(query, arms, k) do
    arms
    |> Enum.reduce_while({:ok, []}, fn arm, {:ok, acc} ->
      case resolve_arm(query, arm, k) do
        {:ok, arm_map} -> {:cont, {:ok, [arm_map | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = err -> err
    end
  end

  defp resolve_arm(query, {:dense, index_name}, k) do
    with {:ok, index} <- fetch_dense_index(query, index_name),
         {:ok, vector} <- fetch_list_arg(query, :query_vector),
         :ok <- validate_dimensions(vector, index) do
      {:ok, %{kind: :dense, property: index.name, query_vector: vector, k: k}}
    end
  end

  defp resolve_arm(query, {:sparse, index_name}, k) do
    with {:ok, index} <- fetch_sparse_index(query, index_name),
         {:ok, tokens} <- fetch_list_arg(query, :query_tokens),
         {:ok, weights} <- fetch_list_arg(query, :query_weights) do
      {:ok,
       %{
         kind: :sparse,
         tokens_property: index.tokens,
         weights_property: index.weights,
         query_tokens: tokens,
         query_weights: weights,
         k: k
       }}
    end
  end

  defp resolve_arm(query, {:fulltext, property}, k) do
    with :ok <- ensure_attribute(query, property),
         {:ok, text} <- fetch_text_arg(query, :text_query) do
      {:ok, %{kind: :fulltext, property: property, text_query: text, k: k}}
    end
  end

  # fusion (default rrf) + a shared k bounding the fused output + optional weights + group opts.
  defp fuse_opts(opts, k) do
    base = [fusion: Keyword.get(opts, :fusion, :rrf), k: k]

    base =
      case Keyword.fetch(opts, :weights) do
        {:ok, weights} -> Keyword.put(base, :weights, weights)
        :error -> base
      end

    Keyword.merge(base, Keyword.take(opts, [:group_by, :group_size]))
  end

  defp fetch_list_arg(query, name) do
    case Ash.Query.get_argument(query, name) do
      [_ | _] = list -> {:ok, list}
      _ -> {:error, invalid(name, "must be a non-empty list of numbers")}
    end
  end

  defp fetch_text_arg(query, name) do
    case Ash.Query.get_argument(query, name) do
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> {:error, invalid(name, "must be a non-empty string")}
    end
  end

  defp fetch_k(query) do
    case Ash.Query.get_argument(query, :k) do
      k when is_integer(k) and k > 0 -> {:ok, k}
      _ -> {:error, invalid(:k, "must be a positive integer")}
    end
  end

  defp fetch_dense_index(query, name) do
    case Info.vector_index(query.resource, name) do
      %AshArcadic.VectorIndex{} = index -> {:ok, index}
      nil -> {:error, invalid(:index, "names no declared `vector_index` on this resource")}
    end
  end

  defp fetch_sparse_index(query, name) do
    case Info.sparse_vector_index(query.resource, name) do
      %AshArcadic.SparseVectorIndex{} = index -> {:ok, index}
      nil -> {:error, invalid(:index, "names no declared `sparse_vector_index` on this resource")}
    end
  end

  defp ensure_attribute(query, property) do
    if Ash.Resource.Info.attribute(query.resource, property),
      do: :ok,
      else: {:error, invalid(:arms, "full-text arm property names no declared attribute")}
  end

  defp validate_dimensions(vector, %{dimensions: dimensions}) do
    if length(vector) == dimensions do
      :ok
    else
      {:error,
       invalid(:query_vector, "length does not match the declared vector_index dimensions")}
    end
  end

  defp allow_global?(opts), do: Keyword.get(opts, :allow_global?, false) == true

  defp stash(query, vector_search),
    do: Ash.Query.set_context(query, %{vector_search: vector_search})

  # Value-free (Rule 4): carries the argument name + a generic reason, never the value.
  defp invalid(field, message), do: InvalidArgument.exception(field: field, message: message)
end
