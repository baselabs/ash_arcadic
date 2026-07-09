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
    aggregates: [],
    calculations: [],
    params: %{},
    internal?: false
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
          sort: [{atom(), :asc | :desc} | {:expr, String.t(), atom()}],
          aggregates: [Ash.Query.Aggregate.t()],
          calculations: [{Ash.Query.Calculation.t(), Ash.Expr.t()}],
          params: map(),
          internal?: boolean()
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

  @doc """
  Compiles the query to `{cypher, params}`. Emits
  `MATCH (n:<label>) [WHERE …] RETURN n [ORDER BY …] [SKIP n] [LIMIT n]`.
  `label` and every sort field are re-validated as identifiers here
  (defense-in-depth — they feed the statement body; values ride `params`).
  """
  @spec to_cypher(t()) :: {String.t(), map()}
  def to_cypher(%__MODULE__{} = query) do
    label = AshArcadic.Identifier.validate!(query.label)
    {where_parts, query} = build_where(query)

    parts =
      ["MATCH (n:#{label})"] ++
        build_where_clause(where_parts) ++
        ["RETURN n"] ++
        build_order_by(query.sort) ++
        build_skip(query.offset) ++
        build_limit(query.limit)

    {Enum.join(parts, " "), query.params}
  end

  defp next_param_key(params, n) do
    key = "param#{n}"
    if Map.has_key?(params, key), do: next_param_key(params, n + 1), else: key
  end

  defp build_where(query) do
    {expression_clauses, query} =
      if query.expression do
        case AshArcadic.Query.Filter.translate(query.expression, query) do
          {:ok, query, ""} -> {[], query}
          {:ok, query, clause} -> {[clause], query}
          # FAIL CLOSED: a rejectable expression must NEVER silently drop its WHERE
          # clause → an unscoped all-rows read (fail-open scoping bug, AGENTS.md Rule 2).
          # Raise the value-free UnsupportedFilter — consistent with to_cypher's
          # invalid-label/offset/limit raises. Latent today (runtime scoping goes
          # filter/3 → query.filters, fail-closed; :expression is never written in lib/),
          # but this closes the trap for any future lazy-expression wiring.
          {:error, err} -> raise err
        end
      else
        {[], query}
      end

    {query.filters ++ expression_clauses, query}
  end

  defp build_where_clause([]), do: []
  defp build_where_clause(parts), do: ["WHERE " <> Enum.join(parts, " AND ")]

  defp build_order_by([]), do: []

  defp build_order_by(sort_clauses) do
    ["ORDER BY " <> Enum.map_join(sort_clauses, ", ", &order_fragment/1)]
  end

  # An expression sort fragment is already parameterized Cypher (Expression validated the
  # identifier via its Ref guard). ArcadeDB's native nil placement applies (ASC → nulls last;
  # probe-verified); the *_nils_first/last direction qualifiers map to the base ASC/DESC (a
  # documented fidelity note).
  defp order_fragment({:expr, cypher, direction}), do: "#{cypher} #{order_dir(direction)}"

  defp order_fragment({field, direction}) do
    field = AshArcadic.Identifier.validate!(field)
    "n.#{field} #{order_dir(direction)}"
  end

  defp order_dir(:desc), do: "DESC"
  defp order_dir(:desc_nils_first), do: "DESC"
  defp order_dir(:desc_nils_last), do: "DESC"
  defp order_dir(_), do: "ASC"

  defp build_skip(nil), do: []
  defp build_skip(offset) when is_integer(offset) and offset >= 0, do: ["SKIP #{offset}"]

  defp build_skip(offset) do
    raise ArgumentError, "invalid offset: #{inspect(offset)} (expected a non-negative integer)"
  end

  defp build_limit(nil), do: []
  defp build_limit(limit) when is_integer(limit) and limit >= 0, do: ["LIMIT #{limit}"]

  defp build_limit(limit) do
    raise ArgumentError, "invalid limit: #{inspect(limit)} (expected a non-negative integer)"
  end
end
