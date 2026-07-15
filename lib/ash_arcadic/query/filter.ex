defmodule AshArcadic.Query.Filter do
  @moduledoc """
  Translates an `Ash.Filter` expression into a parameterized Cypher `WHERE`
  fragment. Only operators ArcadeDB can push down are emitted; anything else
  returns `{:error, %UnsupportedFilter{}}` carrying operator/field only (never the
  value — AGENTS.md Rule 4).

  Every value rides a bound `$param` (`AshArcadic.Query.add_param/2`); every
  attribute name is validated as an `Arcadic.Identifier` first (R1 — the filter
  side the AGE port left unvalidated). Range operators are rejected on
  non-range-comparable storage (binary base64; `:decimal` exact-string, D27) so a
  range filter fails LOUD, never lexicographically wrong.

  ## Supported
  eq · not_eq · gt · lt · gte · lte · in · is_nil · and · or · not ·
  contains · string_starts_with · string_ends_with · literal `true`/`false`
  (Ash lowers a no-match `exists(rel, …)` to a bare boolean) · a filter ON an
  EXPRESSION calculation Ref (expanded to Cypher via `AshArcadic.Query.Expression`) ·
  a raw compound value-expression comparison (`a + b > 5`, `first <> last == "x"`)

  ## Not supported (→ UnsupportedFilter)
  like · ilike · attribute-to-attribute comparisons · a filter ON an AGGREGATE Ref
  or a MODULE (non-expression) calculation Ref (a COMPUTED value not Cypher-expressible
  — Finding A)

  ArcadeDB `CONTAINS`/`STARTS WITH`/`ENDS WITH` are case-SENSITIVE; a `:ci_string`
  attribute's case-insensitive semantics are not preserved (usage-rules).
  """

  require Ash.Query

  alias AshArcadic.Cast
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Errors.UnsupportedFilter
  alias AshArcadic.Identifier
  alias AshArcadic.Query
  alias AshArcadic.Query.Expression

  @comparison_ops %{
    Ash.Query.Operator.Eq => "=",
    Ash.Query.Operator.NotEq => "<>",
    Ash.Query.Operator.GreaterThan => ">",
    Ash.Query.Operator.LessThan => "<",
    Ash.Query.Operator.GreaterThanOrEqual => ">=",
    Ash.Query.Operator.LessThanOrEqual => "<="
  }

  @doc "Translate an Ash filter expression into a Cypher WHERE fragment + params."
  @spec translate(term(), Query.t()) :: {:ok, Query.t(), String.t()} | {:error, term()}
  def translate(%Ash.Filter{expression: nil}, query), do: {:ok, query, ""}
  def translate(%Ash.Filter{expression: expression}, query), do: do_translate(expression, query)
  def translate(filter, query), do: do_translate(filter, query)

  defp do_translate(%Ash.Query.BooleanExpression{op: :and, left: l, right: r}, query) do
    with {:ok, query, lc} <- do_translate(l, query),
         {:ok, query, rc} <- do_translate(r, query) do
      {:ok, query, "(#{lc} AND #{rc})"}
    end
  end

  defp do_translate(%Ash.Query.BooleanExpression{op: :or, left: l, right: r}, query) do
    with {:ok, query, lc} <- do_translate(l, query),
         {:ok, query, rc} <- do_translate(r, query) do
      {:ok, query, "(#{lc} OR #{rc})"}
    end
  end

  defp do_translate(%Ash.Query.Not{expression: expr}, query) do
    with {:ok, query, clause} <- do_translate(expr, query) do
      {:ok, query, "NOT (#{clause})"}
    end
  end

  # A literal boolean filter expression (Ash lowers `exists(rel, …)` over an EMPTY match set — and a
  # constant-folded predicate — to a bare `true`/`false`). Emit the Cypher literal directly: ArcadeDB
  # `WHERE true` matches every row, `WHERE false` matches none (both probe-verified). Without this a
  # no-match `exists` hits the catch-all and fails with a spurious %UnsupportedFilter{} (a wrong error
  # for a legitimately-empty result).
  defp do_translate(true, query), do: {:ok, query, "true"}
  defp do_translate(false, query), do: {:ok, query, "false"}

  # Finding A (relaxed, Slice 7): an EXPRESSION calc Ref on the left of a comparison → expand and
  # translate via Expression (which re-classifies the expansion: a nested aggregate/module-calc Ref
  # rejects). A MODULE calc Ref → reject value-free (not Cypher-expressible).
  defp do_translate(
         %mod{
           left: %Ash.Query.Ref{attribute: %Ash.Query.Calculation{module: cm}} = ref,
           right: right
         } =
           expr,
         query
       )
       when is_map_key(@comparison_ops, mod) do
    if Ash.Resource.Calculation.has_expression?(cm) do
      compound_compare(query, ref, right, Map.fetch!(@comparison_ops, mod))
    else
      # Reject the ORIGINAL expr (a variable-module `%mod{}` cannot be RE-constructed — Elixir requires
      # a compile-time struct name); unsupported_shape/1 derives {operator, calc-name} value-free.
      reject_unsupported(expr)
    end
  end

  # An aggregate Ref on the left → reject value-free (computed, not a stored property — Finding A).
  defp do_translate(%_op{left: %Ash.Query.Ref{attribute: %Ash.Query.Aggregate{}}} = expr, _query) do
    reject_unsupported(expr)
  end

  # Function form (`contains(some_calc, …)` carries `arguments:`) with an aggregate/calc Ref first arg
  # is a COMPUTED value, not a stored ArcadeDB property — reject structurally BEFORE the function
  # clauses, mirroring the Ref-to-Ref guard's shape + unsupported_shape/1 derivation. Value-free.
  defp do_translate(%_op{arguments: [%Ash.Query.Ref{attribute: %agg_mod{}} | _]} = expr, _query)
       when agg_mod in [Ash.Query.Aggregate, Ash.Query.Calculation] do
    reject_unsupported(expr)
  end

  # Attribute-to-attribute comparison carries a Ref on the right — no bindable
  # value. Reject structurally BEFORE the operator clauses.
  defp do_translate(%mod{left: %Ash.Query.Ref{}, right: %Ash.Query.Ref{}} = expr, _query)
       when mod in [
              Ash.Query.Operator.Eq,
              Ash.Query.Operator.NotEq,
              Ash.Query.Operator.In,
              Ash.Query.Operator.GreaterThan,
              Ash.Query.Operator.LessThan,
              Ash.Query.Operator.GreaterThanOrEqual,
              Ash.Query.Operator.LessThanOrEqual
            ] do
    reject_unsupported(expr)
  end

  # A comparison whose RIGHT operand is itself a value-EXPRESSION (a + b, first <> last, a function) —
  # the plain-Ref clauses below would param-bind the RHS expression STRUCT verbatim (an unevaluated
  # %Plus{}/%Concat{} bound as a Cypher param → wrong result / transport crash). Route BOTH operands
  # through Expression instead (mirrors the compound-LEFT clause). An expression node carries
  # `:__predicate__?` (operators AND functions); a Ref RHS (attribute-to-attribute) is rejected above,
  # and a literal or literal-struct (Decimal/Date) RHS lacks the key and falls to the param-bind
  # clauses below — so only genuine value-expression RHSs are intercepted.
  defp do_translate(%mod{left: %Ash.Query.Ref{} = ref, right: right}, query)
       when is_map_key(@comparison_ops, mod) and is_struct(right) and
              is_map_key(right, :__predicate__?) do
    compound_compare(query, ref, right, Map.fetch!(@comparison_ops, mod))
  end

  defp do_translate(
         %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    binary_op(query, attr, "=", value, Ash.Query.Operator.Eq)
  end

  defp do_translate(
         %Ash.Query.Operator.NotEq{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    binary_op(query, attr, "<>", value, Ash.Query.Operator.NotEq)
  end

  defp do_translate(
         %Ash.Query.Operator.GreaterThan{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    range_op(query, attr, ">", value, Ash.Query.Operator.GreaterThan)
  end

  defp do_translate(
         %Ash.Query.Operator.LessThan{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    range_op(query, attr, "<", value, Ash.Query.Operator.LessThan)
  end

  defp do_translate(
         %Ash.Query.Operator.GreaterThanOrEqual{
           left: %Ash.Query.Ref{attribute: attr},
           right: value
         },
         query
       ) do
    range_op(query, attr, ">=", value, Ash.Query.Operator.GreaterThanOrEqual)
  end

  defp do_translate(
         %Ash.Query.Operator.LessThanOrEqual{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    range_op(query, attr, "<=", value, Ash.Query.Operator.LessThanOrEqual)
  end

  # In.right is a MapSet — normalize to a list and reuse the list clause.
  defp do_translate(
         %Ash.Query.Operator.In{left: %Ash.Query.Ref{} = ref, right: %MapSet{} = values},
         query
       ) do
    do_translate(%Ash.Query.Operator.In{left: ref, right: MapSet.to_list(values)}, query)
  end

  defp do_translate(
         %Ash.Query.Operator.In{left: %Ash.Query.Ref{attribute: attr}, right: values},
         query
       )
       when is_list(values) do
    cond do
      not filterable_field?(query, attr) ->
        {:error,
         UnsupportedFilter.exception(operator: Ash.Query.Operator.In, field: attr_name(attr))}

      Enum.any?(values, &match?(%Ash.Query.Ref{}, &1)) ->
        {:error,
         UnsupportedFilter.exception(operator: Ash.Query.Operator.In, field: attr_name(attr))}

      true ->
        in_clause(query, attr, values)
    end
  end

  # is_nil / not is_nil is a presence check — allowed on any STORED property (including a `sensitive`
  # one: the documented presence oracle, D9), but rejected on a NON-STORED (skip-ped) field, whose
  # absent property would make `n.<f> IS NULL` match EVERY row (ArcadeDB reads a missing property as
  # null) — the same silent-wrong-result footgun `filterable_field?/2` closes for value comparisons.
  defp do_translate(
         %Ash.Query.Operator.IsNil{left: %Ash.Query.Ref{attribute: attr}, right: right},
         query
       )
       when is_boolean(right) do
    cond do
      not presence_checkable?(query, attr) ->
        {:error,
         UnsupportedFilter.exception(operator: Ash.Query.Operator.IsNil, field: attr_name(attr))}

      right ->
        {:ok, query, "n.#{identifier(attr)} IS NULL"}

      true ->
        {:ok, query, "n.#{identifier(attr)} IS NOT NULL"}
    end
  end

  # A string function whose non-first argument is a Ref is an attribute-to-attribute comparison in
  # function form (contains(name, other_ref)) — no bindable value. Reject structurally BEFORE the
  # function clauses, mirroring the operator Ref-to-Ref guard. Covers a plain OR aggregate/calc Ref.
  defp do_translate(%mod{arguments: [%Ash.Query.Ref{}, %Ash.Query.Ref{} | _]} = expr, _query)
       when mod in [
              Ash.Query.Function.Contains,
              Ash.Query.Function.StringStartsWith,
              Ash.Query.Function.StringEndsWith
            ] do
    reject_unsupported(expr)
  end

  defp do_translate(
         %Ash.Query.Function.Contains{arguments: [%Ash.Query.Ref{attribute: attr}, value]},
         query
       ) do
    string_op(query, attr, "CONTAINS", value, Ash.Query.Function.Contains)
  end

  defp do_translate(
         %Ash.Query.Function.StringStartsWith{
           arguments: [%Ash.Query.Ref{attribute: attr}, value]
         },
         query
       ) do
    string_op(query, attr, "STARTS WITH", value, Ash.Query.Function.StringStartsWith)
  end

  defp do_translate(
         %Ash.Query.Function.StringEndsWith{arguments: [%Ash.Query.Ref{attribute: attr}, value]},
         query
       ) do
    string_op(query, attr, "ENDS WITH", value, Ash.Query.Function.StringEndsWith)
  end

  # A raw compound-left comparison (a + b > 5, first <> last == "x", a calc-expanded expression) →
  # translate both operands via Expression, emit (<left>) OP (<right>). Placed AFTER the plain-Ref
  # fast paths and the Ref-to-Ref guard, so only NON-plain-Ref (value-expression) lefts reach here.
  defp do_translate(%mod{left: left, right: right}, query)
       when is_map_key(@comparison_ops, mod) do
    compound_compare(query, left, right, Map.fetch!(@comparison_ops, mod))
  end

  # Catch-all: unsupported. Surface operator/function module + field only.
  defp do_translate(expr, _query) do
    reject_unsupported(expr)
  end

  # Both operands through Expression (which handles Ref → guarded n.field, calc-Ref → expand,
  # value-expression → recurse, literal → bound $param). An unsupported node fails closed value-free.
  defp compound_compare(query, left, right, cypher_op) do
    with {:ok, query, lc} <- Expression.translate(left, query),
         {:ok, query, rc} <- Expression.translate(right, query) do
      {:ok, query, "(#{lc} #{cypher_op} #{rc})"}
    end
  end

  defp binary_op(query, attr, cypher_op, value, operator) do
    if filterable_field?(query, attr) do
      field = identifier(attr)
      {query, ref} = Query.add_param(query, cast_value(value, attr))
      {:ok, query, "n.#{field} #{cypher_op} #{temporal_wrap(ref, attr)}"}
    else
      {:error, UnsupportedFilter.exception(operator: operator, field: attr_name(attr))}
    end
  end

  # Wrap a bound comparison param in the attribute's Cypher temporal constructor
  # (`datetime($p)`/`localtime($p)`) so ArcadeDB compares temporal-to-temporal — a bare string param
  # against a coerced temporal property silently matches nothing (Cast.temporal_cypher_fn/2). A
  # non-temporal (or `:date`) attr returns the ref unchanged.
  defp temporal_wrap(ref, attr) do
    case Cast.temporal_cypher_fn(attr_type(attr), attr_constraints(attr)) do
      nil -> ref
      fun -> "#{fun}(#{ref})"
    end
  end

  # `field IN [...]`. A NON-temporal attr binds the whole list as one param (`IN $p`). A coerced
  # temporal attr binds each element separately and wraps it (`IN [datetime($p1), datetime($p2)]`) —
  # a bare string list never matches coerced temporal values (same silent-[] bug as scalar compare).
  defp in_clause(query, attr, values) do
    field = identifier(attr)

    case Cast.temporal_cypher_fn(attr_type(attr), attr_constraints(attr)) do
      nil ->
        {query, ref} = Query.add_param(query, Enum.map(values, &cast_value(&1, attr)))
        {:ok, query, "n.#{field} IN #{ref}"}

      fun ->
        {query, wrapped} =
          Enum.reduce(values, {query, []}, fn value, {q, acc} ->
            {q, ref} = Query.add_param(q, cast_value(value, attr))
            {q, ["#{fun}(#{ref})" | acc]}
          end)

        {:ok, query, "n.#{field} IN [#{wrapped |> Enum.reverse() |> Enum.join(", ")}]"}
    end
  end

  defp string_op(query, attr, cypher_op, value, operator),
    do: binary_op(query, attr, cypher_op, value, operator)

  defp range_op(query, attr, cypher_op, value, operator) do
    if Cast.range_comparable?(attr_type(attr), attr_constraints(attr)) do
      binary_op(query, attr, cypher_op, value, operator)
    else
      {:error, UnsupportedFilter.exception(operator: operator, field: attr_name(attr))}
    end
  end

  defp identifier(attr), do: attr.name |> to_string() |> Identifier.validate!()

  defp cast_value(value, attr),
    do: Cast.serialize_value(value, {attr_type(attr), attr_constraints(attr)})

  defp attr_type(%{type: type}), do: type
  defp attr_type(_attr), do: nil

  defp attr_constraints(%{constraints: constraints}) when is_list(constraints), do: constraints
  defp attr_constraints(_attr), do: []

  # Value-free rejection shared by the aggregate/calc-Ref guards, the attribute-to-attribute guard,
  # and the catch-all — derive {operator, field} from the expression shape, never the value.
  defp reject_unsupported(expr) do
    {operator, field} = unsupported_shape(expr)
    {:error, UnsupportedFilter.exception(operator: operator, field: field)}
  end

  defp unsupported_shape(%mod{left: %Ash.Query.Ref{attribute: %{name: name}}}), do: {mod, name}

  defp unsupported_shape(%mod{left: %Ash.Query.Ref{attribute: name}}) when is_atom(name),
    do: {mod, name}

  defp unsupported_shape(%mod{arguments: [%Ash.Query.Ref{attribute: %{name: name}} | _]}),
    do: {mod, name}

  defp unsupported_shape(%mod{}), do: {mod, nil}
  defp unsupported_shape(_other), do: {:unsupported_expression, nil}

  # A field is filterable when it is a STORED ArcadeDB property (mirrors the sort path's
  # Info.stored_field?/2 guard — a skip-ped/computed field emits n.<f> against a missing property →
  # silent []) AND not `sensitive` (app-side-encrypted binary — plaintext comparison is meaningless;
  # see usage-rules for the searchable-field escape hatch). Gated on Ash.Resource.Info.resource?/1
  # because Info.stored_field?/sensitive RAISE on a non-arcade module, and translate is reachable with
  # a resource-less query (changeset_where pre-thread) or a bare test-fixture module (aggregate filters).
  # An unknown resource cannot be checked → do NOT reject (the guard is fail-safe, not fail-closed here;
  # the write path threads the real resource so the guard actually fires — see changeset_where).
  defp filterable_field?(%AshArcadic.Query{resource: resource}, attr)
       when is_atom(resource) and not is_nil(resource) do
    if Ash.Resource.Info.resource?(resource) do
      Info.value_translatable_field?(resource, attr_name(attr))
    else
      true
    end
  end

  defp filterable_field?(_query, _attr), do: true

  # A presence check (is_nil/not_nil) is meaningful only on a STORED ArcadeDB property. Unlike
  # `filterable_field?/2`, a `sensitive` (but stored) field IS presence-checkable — is_nil on a
  # sensitive field is the documented presence oracle (D9), reads no value — so this guards on
  # `stored_field?` ALONE, not the sensitive check. Same nil-/non-resource-safe fallthrough as the
  # value guard (an unknown resource cannot be checked → do not reject; the write path threads the
  # real resource so the guard fires).
  defp presence_checkable?(%AshArcadic.Query{resource: resource}, attr)
       when is_atom(resource) and not is_nil(resource) do
    if Ash.Resource.Info.resource?(resource) do
      Info.stored_field?(resource, attr_name(attr))
    else
      true
    end
  end

  defp presence_checkable?(_query, _attr), do: true

  defp attr_name(%{name: name}), do: name
  defp attr_name(name) when is_atom(name), do: name
end
