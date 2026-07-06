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

  defp ident(field), do: field |> to_string() |> Identifier.validate!()
end
