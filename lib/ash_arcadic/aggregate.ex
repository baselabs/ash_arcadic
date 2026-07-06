defmodule AshArcadic.Aggregate do
  @moduledoc """
  Pure aggregate Cypher builder + decoder for AshArcadic. Builds ONE parameterized
  statement per `Ash.Query.Aggregate` (each carries its own filter/field/uniq?/
  include_nil?/default_value); RETURN uses SYNTHETIC aliases (`agg<i>`), never the
  caller name (Rule 1). Value-reading aggregates over non-summable/non-orderable/
  sensitive (`:binary`) storage fail closed value-free — a correctness guard mirroring
  `{:sort, :binary}` AND a leak guard (a `min`/`list` over an encrypted-binary attr
  would order-by / return ciphertext into the result; §6.4). A `list`/`first` requesting
  `include_nil?: true` also fails closed value-free (ArcadeDB `collect` drops nulls; §6.5).
  Empty sets — and value-reading sets with no non-null field values — decode to the
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

  # `list`/`first` with `include_nil?: true` is unsupportable: ArcadeDB `collect` drops nulls
  # and no null-preserving construction is confirmed (spec §6.5 / S3-19). Fail closed value-free
  # (a clean "not supported" rejection) rather than silently returning a nulls-dropped result.
  def guard_field(%Ash.Query.Aggregate{kind: kind, include_nil?: true}, _types)
      when kind in [:list, :first],
      do: {:error, {:include_nil_unsupported, kind}}

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
  Value-reading kinds return `{expr, :companion}` — a `count(n.<field>) AS <alias>_card`
  companion (inlined here for sum/avg/min/max, appended by `build_statement/3` for `:first`).
  The companion counts NON-NULL field values, so decode maps both an empty set AND an
  all-null-field set (`card == 0`) to the struct default — matching Ash/SQL aggregate
  semantics, which skip nulls (ArcadeDB `sum` over empty/all-null = 0 ≠ Ash nil, probe G7).
  `count`/`exists`/`list` return `{expr, :plain}` (correct as returned; `list` empty → `[]`).
  `<f>` is `Identifier.validate!`-checked. `:first` ordering is emitted by `build_statement/3`
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
    f = ident(field)
    {"#{kind}(n.#{f}) AS #{alias}, count(n.#{f}) AS #{alias}_card", :companion}
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
         :ok <- guard_sort(agg),
         {:ok, query, agg_clause} <- translate_agg_filter(base, agg) do
      label = Identifier.validate!(base.label)
      where = build_where(base.filters ++ agg_clause)
      order = order_prefix(agg)
      {expr, companion} = return_expr(agg, "agg0")
      expr = append_first_companion(expr, companion, agg)
      cypher = "MATCH (n:#{label})" <> order <> where <> " RETURN #{expr}"
      {:ok, cypher, query.params}
    end
  end

  @doc """
  Decodes the single result row for one aggregate to its Ash value (§6.3). When the
  cardinality companion reports `agg0_card == 0` (or an inherently empty result —
  `count → 0`, `list → []`), returns the aggregate struct's `.default_value` (which Ash
  pre-populates as `caller_default || default_value(kind)`) — NOT ArcadeDB's `sum → 0`
  (probe G7). `exists` coerces to a boolean; value-returning kinds (`min`/`max`/`first`
  and `list` elements) coerce through `Cast.load_value/2` by the field's storage type.
  """
  @spec decode([map()], Ash.Query.Aggregate.t(), %{atom() => {Ash.Type.t(), keyword()}}) :: term()
  def decode([], agg, _types), do: agg.default_value

  def decode([row | _], %Ash.Query.Aggregate{kind: :count} = agg, _types),
    do: Map.get(row, "agg0", agg.default_value)

  def decode([row | _], %Ash.Query.Aggregate{kind: :exists}, _types),
    do: Map.get(row, "agg0") == true

  def decode([row | _], %Ash.Query.Aggregate{kind: :list, field: field} = agg, types) do
    case Map.get(row, "agg0") do
      nil -> agg.default_value
      [] -> agg.default_value
      values when is_list(values) -> Enum.map(values, &Cast.load_value(&1, Map.get(types, field)))
    end
  end

  def decode([row | _], %Ash.Query.Aggregate{kind: kind, field: field} = agg, types)
      when kind in [:sum, :avg, :min, :max, :first] do
    if Map.get(row, "agg0_card", 0) == 0 do
      agg.default_value
    else
      coerce_value(kind, Map.get(row, "agg0"), field, types)
    end
  end

  # Only :first needs the companion appended here — the WITH reshapes the row so
  # return_expr leaves it off; :sum/:avg/:min/:max already inline their own companion.
  # The companion counts NON-NULL field values (count(n.<field>)), so an all-null-field set
  # decodes to the Ash default, not the raw collect()-of-nothing head.
  defp append_first_companion(expr, :companion, %Ash.Query.Aggregate{kind: :first, field: field}),
    do: expr <> ", count(n.#{ident(field)}) AS agg0_card"

  defp append_first_companion(expr, _companion, _agg), do: expr

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

  # :first's ORDER BY fields flow through ident/1 (to_string) in order_prefix/1. A non-atom
  # sort field (a %Ash.Query.Calculation{}/%Ash.Query.Aggregate{} — both valid Ash.Sort.t())
  # would raise Protocol.UndefinedError carrying the struct (its opts embed caller literals) —
  # the symmetric Rule-4 leak guard_field/2 closes for agg.field. Reject value-free BEFORE any
  # to_string. Only :first consults query.sort; every other kind ignores it.
  defp guard_sort(%Ash.Query.Aggregate{kind: :first, query: %{sort: [_ | _] = sort}}) do
    if Enum.all?(sort, &sort_field_atom?/1), do: :ok, else: {:error, :expression_sort}
  end

  defp guard_sort(_agg), do: :ok

  defp sort_field_atom?({field, _dir}), do: is_atom(field)
  defp sort_field_atom?(field), do: is_atom(field)

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

  # sum/avg are numeric already (no string storage — guarded); min/max/first return a
  # stored value of the field's type → coerce like a read row (decimal→Decimal, etc.).
  defp coerce_value(kind, value, _field, _types) when kind in [:sum, :avg], do: value
  defp coerce_value(_kind, value, field, types), do: Cast.load_value(value, Map.get(types, field))

  defp ident(field), do: field |> to_string() |> Identifier.validate!()
end
