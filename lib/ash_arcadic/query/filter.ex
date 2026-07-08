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
  (Ash lowers a no-match `exists(rel, …)` to a bare boolean)

  ## Not supported (→ UnsupportedFilter)
  like · ilike · attribute-to-attribute comparisons · a filter ON an aggregate or
  calculation Ref (a COMPUTED value, not a stored property — Finding A)

  ArcadeDB `CONTAINS`/`STARTS WITH`/`ENDS WITH` are case-SENSITIVE; a `:ci_string`
  attribute's case-insensitive semantics are not preserved (usage-rules).
  """

  require Ash.Query

  alias AshArcadic.Cast
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Errors.UnsupportedFilter
  alias AshArcadic.Identifier
  alias AshArcadic.Query

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

  # Finding A: an aggregate/calculation Ref is a COMPUTED value, not a stored ArcadeDB property —
  # emitting `n.<name> > $p` silently matches nothing ({:ok, []}, a wrong result). Reject structurally,
  # BEFORE the operator clauses, mirroring the Ref-to-Ref guard's shape + unsupported_shape/1 derivation.
  # The first clause covers operator forms (`post_count > 1` carries `left:`); the second covers function
  # forms (`contains(some_calc, …)` carries `arguments:`). Value-free (names the aggregate + operator).
  defp do_translate(%_op{left: %Ash.Query.Ref{attribute: %agg_mod{}}} = expr, _query)
       when agg_mod in [Ash.Query.Aggregate, Ash.Query.Calculation] do
    reject_unsupported(expr)
  end

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
        field = identifier(attr)
        {query, ref} = Query.add_param(query, Enum.map(values, &cast_value(&1, attr)))
        {:ok, query, "n.#{field} IN #{ref}"}
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

  # Catch-all: unsupported. Surface operator/function module + field only.
  defp do_translate(expr, _query) do
    reject_unsupported(expr)
  end

  defp binary_op(query, attr, cypher_op, value, operator) do
    if filterable_field?(query, attr) do
      field = identifier(attr)
      {query, ref} = Query.add_param(query, cast_value(value, attr))
      {:ok, query, "n.#{field} #{cypher_op} #{ref}"}
    else
      {:error, UnsupportedFilter.exception(operator: operator, field: attr_name(attr))}
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
      name = attr_name(attr)
      Info.stored_field?(resource, name) and name not in Info.sensitive(resource)
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
