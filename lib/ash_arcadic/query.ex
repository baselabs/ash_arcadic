defmodule AshArcadic.Query do
  @moduledoc """
  Query structure for AshArcadic. Accumulates filters/sort/limit/offset; compiled
  to Cypher by `to_cypher/1` (Plan 2). `client`/`database`/`label` come from the
  resource's `arcade` DSL; `database` is overridden per-tenant by `set_tenant/3`
  for `:context` resources (Plan 2).
  """
  defstruct [
    :resource,
    :client,
    :database,
    :label,
    :tenant,
    :expression,
    :limit,
    :offset,
    filters: [],
    sort: [],
    params: %{}
  ]

  @type t :: %__MODULE__{
          resource: module(),
          client: module() | nil,
          database: String.t() | nil,
          label: atom() | String.t() | nil,
          tenant: term() | nil,
          expression: Ash.Filter.t() | nil,
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          filters: [String.t()],
          sort: [{atom(), :asc | :desc}],
          params: map()
        }

  @doc """
  Adds a parameter to the query, returning the updated query and a `$paramN`
  reference. Skips any `paramN` key already present so a seeded key (SET-attribute
  or `match_<pk>` on the update/destroy path) is never clobbered.
  """
  @spec add_param(t(), term()) :: {t(), String.t()}
  def add_param(%__MODULE__{params: params} = query, value) do
    key = next_param_key(params, map_size(params) + 1)
    {%{query | params: Map.put(params, key, value)}, "$#{key}"}
  end

  defp next_param_key(params, n) do
    key = "param#{n}"
    if Map.has_key?(params, key), do: next_param_key(params, n + 1), else: key
  end
end
