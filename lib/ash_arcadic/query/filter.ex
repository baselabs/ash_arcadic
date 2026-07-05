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
  contains · string_starts_with · string_ends_with

  ## Not supported (→ UnsupportedFilter)
  like · ilike · attribute-to-attribute comparisons · aggregate/exists subqueries

  ArcadeDB `CONTAINS`/`STARTS WITH`/`ENDS WITH` are case-SENSITIVE; a `:ci_string`
  attribute's case-insensitive semantics are not preserved (usage-rules).
  """

  require Ash.Query

  alias AshArcadic.Cast
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
    {operator, field} = unsupported_shape(expr)
    {:error, UnsupportedFilter.exception(operator: operator, field: field)}
  end

  defp do_translate(
         %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    binary_op(query, attr, "=", value)
  end

  defp do_translate(
         %Ash.Query.Operator.NotEq{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    binary_op(query, attr, "<>", value)
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
    if Enum.any?(values, &match?(%Ash.Query.Ref{}, &1)) do
      {:error, UnsupportedFilter.exception(operator: Ash.Query.Operator.In, field: attr.name)}
    else
      field = identifier(attr)
      {query, ref} = Query.add_param(query, Enum.map(values, &cast_value(&1, attr)))
      {:ok, query, "n.#{field} IN #{ref}"}
    end
  end

  defp do_translate(
         %Ash.Query.Operator.IsNil{left: %Ash.Query.Ref{attribute: attr}, right: true},
         query
       ) do
    {:ok, query, "n.#{identifier(attr)} IS NULL"}
  end

  defp do_translate(
         %Ash.Query.Operator.IsNil{left: %Ash.Query.Ref{attribute: attr}, right: false},
         query
       ) do
    {:ok, query, "n.#{identifier(attr)} IS NOT NULL"}
  end

  defp do_translate(
         %Ash.Query.Function.Contains{arguments: [%Ash.Query.Ref{attribute: attr}, value]},
         query
       ) do
    string_op(query, attr, "CONTAINS", value)
  end

  defp do_translate(
         %Ash.Query.Function.StringStartsWith{
           arguments: [%Ash.Query.Ref{attribute: attr}, value]
         },
         query
       ) do
    string_op(query, attr, "STARTS WITH", value)
  end

  defp do_translate(
         %Ash.Query.Function.StringEndsWith{arguments: [%Ash.Query.Ref{attribute: attr}, value]},
         query
       ) do
    string_op(query, attr, "ENDS WITH", value)
  end

  # Catch-all: unsupported. Surface operator/function module + field only.
  defp do_translate(expr, _query) do
    {operator, field} = unsupported_shape(expr)
    {:error, UnsupportedFilter.exception(operator: operator, field: field)}
  end

  defp binary_op(query, attr, cypher_op, value) do
    field = identifier(attr)
    {query, ref} = Query.add_param(query, cast_value(value, attr))
    {:ok, query, "n.#{field} #{cypher_op} #{ref}"}
  end

  defp string_op(query, attr, cypher_op, value), do: binary_op(query, attr, cypher_op, value)

  defp range_op(query, attr, cypher_op, value, operator) do
    if Cast.range_comparable?(attr_type(attr), attr_constraints(attr)) do
      binary_op(query, attr, cypher_op, value)
    else
      {:error, UnsupportedFilter.exception(operator: operator, field: attr.name)}
    end
  end

  defp identifier(attr), do: attr.name |> to_string() |> Identifier.validate!()

  defp cast_value(value, attr),
    do: Cast.serialize_value(value, {attr_type(attr), attr_constraints(attr)})

  defp attr_type(%{type: type}), do: type
  defp attr_type(_attr), do: nil

  defp attr_constraints(%{constraints: constraints}) when is_list(constraints), do: constraints
  defp attr_constraints(_attr), do: []

  defp unsupported_shape(%mod{left: %Ash.Query.Ref{attribute: %{name: name}}}), do: {mod, name}

  defp unsupported_shape(%mod{left: %Ash.Query.Ref{attribute: name}}) when is_atom(name),
    do: {mod, name}

  defp unsupported_shape(%mod{arguments: [%Ash.Query.Ref{attribute: %{name: name}} | _]}),
    do: {mod, name}

  defp unsupported_shape(%mod{}), do: {mod, nil}
  defp unsupported_shape(_other), do: {:unsupported_expression, nil}
end
