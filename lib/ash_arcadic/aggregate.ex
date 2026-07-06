defmodule AshArcadic.Aggregate do
  @moduledoc """
  Pure aggregate Cypher builder + decoder for AshArcadic. Builds ONE parameterized
  statement per `Ash.Query.Aggregate` (each carries its own filter/field/uniq?/
  include_nil?/default_value); RETURN uses SYNTHETIC aliases (`agg<i>`), never the
  caller name (Rule 1). Value-reading aggregates over non-summable/non-orderable/
  sensitive (`:binary`) storage fail closed value-free — a correctness guard mirroring
  `{:sort, :binary}` AND a leak guard (a `min`/`list` over an encrypted-binary attr
  would order-by / return ciphertext into the result; §6.4). Empty sets decode to the
  aggregate struct's own `.default_value` (spec §6.3).
  """

  alias AshArcadic.Cast
  alias AshArcadic.Identifier
  alias AshArcadic.Query
  alias AshArcadic.Query.Filter

  @value_reading ~w(sum avg min max first list)a

  @doc """
  Guards an aggregate's field against its kind's storage requirement (§6.4). Returns
  `:ok` or a value-free `{:error, reason}` (names field + kind only, never the value).
  `count`/`exists` are always allowed (read only presence). A non-atom `field`
  (expression/calculation aggregate) is not Cypher-expressible → `{:error,
  :expression_field}` (never `to_string`-ed — that would raise carrying the struct).
  """
  @spec guard_field(Ash.Query.Aggregate.t(), %{atom() => {Ash.Type.t(), keyword()}}) ::
          :ok | {:error, term()}
  def guard_field(%Ash.Query.Aggregate{kind: :custom}, _types),
    do: {:error, {:unsupported_kind, :custom}}

  def guard_field(%Ash.Query.Aggregate{field: field}, _types)
      when not is_nil(field) and not is_atom(field),
      do: {:error, :expression_field}

  def guard_field(%Ash.Query.Aggregate{kind: kind}, _types) when kind in [:count, :exists],
    do: :ok

  def guard_field(%Ash.Query.Aggregate{kind: kind, field: field}, types)
      when kind in @value_reading do
    {type, constraints} = Map.get(types, field, {nil, []})

    ok? =
      case kind do
        k when k in [:sum, :avg] ->
          not is_nil(type) and Cast.numeric_storage?(type, constraints)

        k when k in [:min, :max, :first] ->
          not is_nil(type) and Cast.range_comparable?(type, constraints)

        :list ->
          not is_nil(type) and not Cast.binary_storage?(type, constraints)
      end

    if ok?, do: :ok, else: {:error, {:unaggregatable, field, kind}}
  end

  @doc """
  The RETURN expression for one aggregate, aliased to `alias` (a synthetic `agg<i>`).
  Value-reading kinds return `{expr, :companion}` — the caller appends `count(n) AS
  <alias>_card` so decode can map an empty set (`card == 0`) to the struct default
  (ArcadeDB `sum` over empty = 0 ≠ Ash nil, probe G7). `count`/`exists`/`list` return
  `{expr, :plain}` (correct as returned; `list` empty → `[]`). `<f>` is
  `Identifier.validate!`-checked. `:first` ordering is emitted by `build_statement/3`
  (a `WITH n ORDER BY …` prefix), not here.

  Assumes `guard_field/2` has already passed for this aggregate — `field` MUST be an
  atom. A non-atom field would raise `Protocol.UndefinedError` in `ident/1`
  (`to_string/1`), carrying the struct (the exact Rule-4 leak `guard_field/2`
  prevents); `build_statement/3` gates on `guard_field/2` first.
  """
  @spec return_expr(Ash.Query.Aggregate.t(), String.t()) :: {String.t(), :plain | :companion}
  def return_expr(%Ash.Query.Aggregate{kind: :count, field: nil}, alias),
    do: {"count(n) AS #{alias}", :plain}

  def return_expr(%Ash.Query.Aggregate{kind: :count, field: field, uniq?: uniq?}, alias) do
    inner = if uniq?, do: "DISTINCT n.#{ident(field)}", else: "n.#{ident(field)}"
    {"count(#{inner}) AS #{alias}", :plain}
  end

  def return_expr(%Ash.Query.Aggregate{kind: :exists}, alias),
    do: {"count(n) > 0 AS #{alias}", :plain}

  def return_expr(%Ash.Query.Aggregate{kind: :list, field: field, uniq?: uniq?}, alias) do
    inner = if uniq?, do: "DISTINCT n.#{ident(field)}", else: "n.#{ident(field)}"
    {"collect(#{inner}) AS #{alias}", :plain}
  end

  def return_expr(%Ash.Query.Aggregate{kind: :first, field: field}, alias),
    do: {"head(collect(n.#{ident(field)})) AS #{alias}", :companion}

  def return_expr(%Ash.Query.Aggregate{kind: kind, field: field}, alias)
      when kind in [:sum, :avg, :min, :max] do
    {"#{kind}(n.#{ident(field)}) AS #{alias}, count(n) AS #{alias}_card", :companion}
  end

  @doc """
  Builds `{:ok, cypher, params}` for ONE aggregate over the base `%AshArcadic.Query{}`,
  or a value-free `{:error, reason}` from the field guard (§6.4). The WHERE ANDs the
  base query's `filters` with the aggregate's OWN `query.filter` (C2 — a shared RETURN
  can't express distinct per-agg filters, so each aggregate is its own statement). The
  RETURN uses synthetic alias `agg0`; value-reading kinds append `count(n) AS agg0_card`
  (§6.1). `:first` prepends `WITH n ORDER BY <agg sort>`.
  """
  @spec build_statement(Query.t(), Ash.Query.Aggregate.t(), %{atom() => {Ash.Type.t(), keyword()}}) ::
          {:ok, String.t(), map()} | {:error, term()}
  def build_statement(%Query{} = base, %Ash.Query.Aggregate{} = agg, types) do
    with :ok <- guard_field(agg, types),
         {:ok, query, agg_clause} <- translate_agg_filter(base, agg) do
      label = Identifier.validate!(base.label)
      where = build_where(base.filters ++ agg_clause)
      order = order_prefix(agg)
      {expr, companion} = return_expr(agg, "agg0")
      expr = append_first_companion(expr, companion, agg.kind)
      cypher = "MATCH (n:#{label})" <> order <> where <> " RETURN #{expr}"
      {:ok, cypher, query.params}
    end
  end

  # Only :first needs the companion appended here — the WITH reshapes the row so
  # return_expr leaves it off; :sum/:avg/:min/:max already inline their own companion.
  defp append_first_companion(expr, :companion, :first), do: expr <> ", count(n) AS agg0_card"
  defp append_first_companion(expr, _companion, _kind), do: expr

  # The aggregate's OWN filter (agg.query.filter), translated against the base query so
  # params accumulate. nil query or nil filter → no extra clause. UnsupportedFilter
  # propagates value-free (fail-closed — never a silently-dropped filter).
  defp translate_agg_filter(base, %Ash.Query.Aggregate{query: %{filter: %Ash.Filter{} = f}}) do
    case Filter.translate(f, base) do
      {:ok, query, ""} -> {:ok, query, []}
      {:ok, query, clause} -> {:ok, query, [clause]}
      {:error, _} = err -> err
    end
  end

  defp translate_agg_filter(base, _agg), do: {:ok, base, []}

  # ORDER BY prefix for :first (uses the aggregate's query.sort; empty → no prefix,
  # first is arbitrary per Ash). Only :first needs a WITH-projection before RETURN.
  defp order_prefix(%Ash.Query.Aggregate{kind: :first, query: %{sort: [_ | _] = sort}}) do
    order =
      Enum.map_join(sort, ", ", fn {field, dir} ->
        d = if dir == :desc, do: "DESC", else: "ASC"
        "n.#{ident(field)} #{d}"
      end)

    " WITH n ORDER BY #{order}"
  end

  defp order_prefix(_agg), do: ""

  defp build_where([]), do: ""
  defp build_where(parts), do: " WHERE " <> Enum.join(parts, " AND ")

  defp ident(field), do: field |> to_string() |> Identifier.validate!()
end
