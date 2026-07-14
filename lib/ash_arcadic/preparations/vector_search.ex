defmodule AshArcadic.Preparations.VectorSearch do
  @moduledoc """
  Read-action preparation that turns an Ash read into a dense vector (kNN) search.
  Attach it to a read action whose arguments carry the query vector and `k`:

      read :semantic_search do
        argument :query_vector, {:array, :float}, allow_nil?: false
        argument :k, :integer, allow_nil?: false
        prepare {AshArcadic.Preparations.VectorSearch, index: :embedding}
      end

  Options:

    * `:index` (required, atom) — the `vector_index` name declared in the `arcade` block.
    * `:allow_global?` (default `false`) — permit a cross-tenant kNN when no tenant is
      resolved. The Ash action must ALSO permit the no-tenant read
      (`multitenancy :allow_global`/`:bypass` or a `global?` resource), else Ash rejects
      it upstream with `TenantRequired` before the data layer runs.
    * `:ef_search`, `:max_distance` — passed through to `Arcadic.Vector.neighbors`.

  It reads the `:query_vector` and `:k` arguments, validates the vector length against the
  declared `vector_index` `dimensions`, and stashes the request onto the query context
  (`:vector_search`), which the data layer's `set_context/3` copies onto
  `%AshArcadic.Query{}`. All failures are value-free (never echo the vector).
  """
  use Ash.Resource.Preparation
  alias Ash.Error.Query.InvalidArgument
  alias AshArcadic.DataLayer.Info

  @passthrough [:ef_search, :max_distance]

  @impl true
  def init(opts) do
    case Keyword.get(opts, :index) do
      index when is_atom(index) and not is_nil(index) ->
        {:ok, opts}

      _ ->
        {:error, "AshArcadic.Preparations.VectorSearch requires an `:index` (atom) option"}
    end
  end

  @impl true
  def prepare(query, opts, _context) do
    index_name = Keyword.fetch!(opts, :index)

    with {:ok, query_vector} <- fetch_query_vector(query),
         {:ok, k} <- fetch_k(query),
         {:ok, index} <- fetch_index(query, index_name),
         :ok <- validate_dimensions(query_vector, index) do
      Ash.Query.set_context(query, %{
        vector_search: %{
          kind: :dense,
          index: index_name,
          query_vector: query_vector,
          k: k,
          allow_global?: Keyword.get(opts, :allow_global?, false) == true,
          opts: Keyword.take(opts, @passthrough)
        }
      })
    else
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  defp fetch_query_vector(query) do
    case Ash.Query.get_argument(query, :query_vector) do
      [_ | _] = vector -> {:ok, vector}
      _ -> {:error, invalid(:query_vector, "must be a non-empty list of numbers")}
    end
  end

  defp fetch_k(query) do
    case Ash.Query.get_argument(query, :k) do
      k when is_integer(k) and k > 0 -> {:ok, k}
      _ -> {:error, invalid(:k, "must be a positive integer")}
    end
  end

  defp fetch_index(query, index_name) do
    case Info.vector_index(query.resource, index_name) do
      %AshArcadic.VectorIndex{} = index -> {:ok, index}
      nil -> {:error, invalid(:index, "names no declared `vector_index` on this resource")}
    end
  end

  defp validate_dimensions(vector, %{dimensions: dimensions}) do
    if length(vector) == dimensions do
      :ok
    else
      {:error,
       invalid(:query_vector, "length does not match the declared vector_index dimensions")}
    end
  end

  # Value-free (Rule 4): carries the argument name + a generic reason, never the vector.
  defp invalid(field, message), do: InvalidArgument.exception(field: field, message: message)
end
