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
end
