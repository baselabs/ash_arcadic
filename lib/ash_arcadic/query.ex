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
    distinct: [],
    distinct_sort: [],
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
          distinct: [{atom(), atom()}],
          distinct_sort: [{atom(), atom()}],
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
      if query.distinct == [] do
        ["MATCH (n:#{label})"] ++
          build_where_clause(where_parts) ++
          ["RETURN n"] ++
          build_order_by(query.sort) ++
          build_skip(query.offset) ++
          build_limit(query.limit)
      else
        build_distinct_parts(query, label, where_parts)
      end

    {Enum.join(parts, " "), query.params}
  end

  # DISTINCT-ON a field subset keeping whole vertices (Ash `distinct` is always DISTINCT-ON, never
  # DISTINCT-*): group by the distinct fields, keep one representative vertex per group. The inner
  # `WITH n ORDER BY <distinct_sort ‖ sort>` picks WHICH vertex survives `collect(n)[0]` — the
  # fallback is the QUERY SORT per the Ash contract ("If none is set, any sort applied to the query
  # will be used", deps/ash query.ex:4285; the ETS reference sorts then dedups), NEVER the distinct
  # fields themselves (a within-group no-op → an engine-arbitrary representative). With neither, the
  # stage is elided (Ash promises no particular representative; the bare collect-group is the
  # probe-confirmed spec §2 shape). The outer `ORDER BY/SKIP/LIMIT` order the deduped result
  # (collect does NOT preserve the pre-WITH order, so the outer sort/paging MUST come after it).
  defp build_distinct_parts(query, label, where_parts) do
    ["MATCH (n:#{label})"] ++
      build_where_clause(where_parts) ++
      distinct_stage_parts(query) ++
      ["RETURN n"] ++
      build_order_by(query.sort) ++
      build_skip(query.offset) ++
      build_limit(query.limit)
  end

  @doc false
  # The collect-group pipeline stages, shared with `AshArcadic.Aggregate` (an aggregate over a
  # distinct query must fold the DEDUPED representatives — ETS-reference parity): the optional
  # representative-order stage (`WITH n ORDER BY <distinct_sort ‖ sort>`, elided when both are
  # empty) followed by the DISTINCT-ON collect stage. Distinct fields are identifier-revalidated
  # here (Rule 1); the `__dN` aliases are compile-generated, never caller data.
  @spec distinct_stage_parts(t()) :: [String.t()]
  def distinct_stage_parts(%__MODULE__{} = query) do
    with_keys =
      query.distinct
      |> Enum.with_index()
      |> Enum.map(fn {{field, _dir}, i} ->
        "n.#{AshArcadic.Identifier.validate!(field)} AS __d#{i}"
      end)

    rep_order = if query.distinct_sort == [], do: query.sort, else: query.distinct_sort
    rep_stage = if rep_order == [], do: [], else: ["WITH n"] ++ build_order_by(rep_order)

    rep_stage ++ ["WITH " <> Enum.join(with_keys ++ ["collect(n)[0] AS n"], ", ")]
  end

  @doc false
  # Outer sort/paging as a WITH stage (the aggregate-over-distinct path): the deduped
  # representatives are sorted/bounded exactly as the read would return them (ETS-reference
  # parity) before the aggregate folds them. Empty when the query carries no limit/offset —
  # an unbounded fold needs no interposed stage.
  @spec paging_stage_parts(t()) :: [String.t()]
  def paging_stage_parts(%__MODULE__{limit: nil, offset: nil}), do: []

  def paging_stage_parts(%__MODULE__{} = query) do
    ["WITH n"] ++
      build_order_by(query.sort) ++ build_skip(query.offset) ++ build_limit(query.limit)
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

  # An expression sort fragment is already parameterized Cypher (Expression validated the identifier
  # via its Ref guard). A field fragment is `n.<field>` (identifier-validated).
  defp order_fragment({:expr, cypher, direction}), do: order_by_expr(cypher, direction)

  defp order_fragment({field, direction}) do
    field = AshArcadic.Identifier.validate!(field)
    order_by_expr("n.#{field}", direction)
  end

  # ArcadeDB native nil placement is ASC → nulls-LAST, DESC → nulls-FIRST (probe-verified), which
  # already matches Ash's DEFAULT convention (:asc ≡ :asc_nils_last, :desc ≡ :desc_nils_first). The
  # explicit OPPOSITE qualifiers (:asc_nils_first, :desc_nils_last) are honored with a leading
  # `(<col> IS NULL)` sort key (probe-verified: `(col IS NULL) DESC` → nulls first; `… ASC` → nulls
  # last), so all four Ash nil-placement qualifiers are faithful (spec D12).
  defp order_by_expr(col, :asc_nils_first), do: "(#{col} IS NULL) DESC, #{col} ASC"
  defp order_by_expr(col, :desc_nils_last), do: "(#{col} IS NULL) ASC, #{col} DESC"
  defp order_by_expr(col, direction), do: "#{col} #{order_dir(direction)}"

  defp order_dir(:desc), do: "DESC"
  defp order_dir(:desc_nils_first), do: "DESC"
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
