defmodule AshArcadic.Query.Expression do
  @moduledoc """
  Translates an Ash value-expression (an expression calculation's body, or a compound
  operand of a filter/sort) into a parameterized Cypher SCALAR. Used by
  `AshArcadic.Query.Filter` (WHERE operands) and the sort path (ORDER BY) — NOT the load
  path (loaded calculations compute in Elixir, `AshArcadic.DataLayer.run_query`).

  Every literal rides a bound `$param` (`Query.add_param/2`); every field name is
  `Identifier.validate!`-d; operators/functions are fixed keywords (Rule 1). A `Ref` to a
  non-stored / `sensitive` / `:binary` / `:decimal` field, or an un-mapped operator/function,
  fails closed value-free (`%UnsupportedFilter{}` — operator/function + field only, Rule 4).
  Division forces float semantics (`toFloat`) to match Ash's integer→float `/`.
  """
  alias AshArcadic.Cast
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Errors.UnsupportedFilter
  alias AshArcadic.Identifier
  alias AshArcadic.Query

  @arith %{
    Ash.Query.Operator.Basic.Plus => "+",
    Ash.Query.Operator.Basic.Minus => "-",
    Ash.Query.Operator.Basic.Times => "*"
  }
  @compare %{
    Ash.Query.Operator.Eq => "=",
    Ash.Query.Operator.NotEq => "<>",
    Ash.Query.Operator.GreaterThan => ">",
    Ash.Query.Operator.LessThan => "<",
    Ash.Query.Operator.GreaterThanOrEqual => ">=",
    Ash.Query.Operator.LessThanOrEqual => "<="
  }
  @unary_fns %{
    Ash.Query.Function.StringDowncase => "lower",
    Ash.Query.Function.StringLength => "size",
    # Ash's list-length `length/1` (distinct from `string_length`) — ArcadeDB `size` is polymorphic
    # over collections and strings (D5: "string_length/length→size").
    Ash.Query.Function.Length => "size",
    Ash.Query.Function.StringTrim => "trim",
    Ash.Query.Function.Round => "round"
  }
  @match_fns %{
    Ash.Query.Function.Contains => "CONTAINS",
    Ash.Query.Function.StringStartsWith => "STARTS WITH",
    Ash.Query.Function.StringEndsWith => "ENDS WITH"
  }

  @spec translate(term(), Query.t()) :: {:ok, Query.t(), String.t()} | {:error, term()}

  # Aggregate Ref — computed, never a stored property. Reject value-free.
  def translate(%Ash.Query.Ref{attribute: %Ash.Query.Aggregate{}}, _query),
    do: {:error, unsupported(Ash.Query.Aggregate, nil)}

  # A relationship-path Ref (author.name) — a RELATED node's property, not a local n.<field>.
  # The local-attr clause below only guards the SOURCE resource, so translating this as `n.<field>`
  # would silently read the source node (fail-open). Relationship calcs are a non-goal; fail closed
  # value-free (field NAME only, never a value). Placed after the aggregate reject so an aggregate
  # rel-path Ref (author.post_count) is still caught by the clause above.
  def translate(%Ash.Query.Ref{relationship_path: [_ | _], attribute: attr}, _query),
    do: {:error, unsupported(:ref, ref_field_name(attr))}

  # Plain-attribute Ref → n.<field>, guarded (stored & not sensitive & range-comparable storage).
  # `relationship_path: []` — a LOCAL ref only; the rel-path clause above rejects the rest.
  def translate(
        %Ash.Query.Ref{relationship_path: [], attribute: %Ash.Resource.Attribute{} = attr},
        %Query{resource: r} = query
      ) do
    if ref_ok?(r, attr) do
      {:ok, query, "n.#{Identifier.validate!(to_string(attr.name))}"}
    else
      {:error, unsupported(:ref, attr.name)}
    end
  end

  # Arithmetic + - * (Ash types operands as numbers).
  def translate(%mod{left: l, right: r}, query) when is_map_key(@arith, mod),
    do: binary(query, l, r, Map.fetch!(@arith, mod))

  # Division → float division (toFloat) to match Ash's integer→float `/`.
  def translate(%Ash.Query.Operator.Basic.Div{left: l, right: r}, query) do
    with {:ok, q1, lc} <- translate(l, query),
         {:ok, q2, rc} <- translate(r, q1) do
      {:ok, q2, "(toFloat(#{lc}) / (#{rc}))"}
    end
  end

  # String concat → + (Ash types operands as strings).
  def translate(%Ash.Query.Operator.Basic.Concat{left: l, right: r}, query),
    do: binary(query, l, r, "+")

  # Comparison → boolean.
  def translate(%mod{left: l, right: r}, query) when is_map_key(@compare, mod),
    do: binary(query, l, r, Map.fetch!(@compare, mod))

  # Boolean operators.
  def translate(%Ash.Query.BooleanExpression{op: op, left: l, right: r}, query) do
    kw = if op == :and, do: "AND", else: "OR"
    binary(query, l, r, kw)
  end

  def translate(%Ash.Query.Not{expression: e}, query) do
    with {:ok, q, c} <- translate(e, query), do: {:ok, q, "NOT (#{c})"}
  end

  # An expression calculation Ref — expand to its expression and recurse (D9). The recursion
  # re-classifies every node post-expansion: a nested aggregate Ref hits the aggregate clause
  # (reject), a nested module (non-expression) calc Ref hits this clause's `else` (reject) — C6.
  def translate(
        %Ash.Query.Ref{attribute: %Ash.Query.Calculation{} = calc},
        %Query{resource: r} = query
      ) do
    if Ash.Resource.Calculation.has_expression?(calc.module) do
      case Ash.Filter.hydrate_refs(
             Ash.Resource.Calculation.expression(calc.module, calc.opts, calc.context),
             %{resource: r, public?: false}
           ) do
        {:ok, hydrated} -> translate(hydrated, query)
        {:error, _} -> {:error, unsupported(Ash.Query.Calculation, calc.name)}
      end
    else
      {:error, unsupported(Ash.Query.Calculation, calc.name)}
    end
  end

  # if(cond, then, else) → CASE WHEN … THEN … ELSE … END.
  def translate(%Ash.Query.Function.If{arguments: [cond, then_v, else_v]}, query) do
    with {:ok, q1, cc} <- translate(cond, query),
         {:ok, q2, tc} <- translate(then_v, q1),
         {:ok, q3, ec} <- translate(else_v, q2) do
      {:ok, q3, "CASE WHEN #{cc} THEN #{tc} ELSE #{ec} END"}
    end
  end

  # A two-arg `if` (no else) → CASE WHEN … THEN … END (Cypher yields null for the unmatched arm,
  # matching Ash's nil-else).
  def translate(%Ash.Query.Function.If{arguments: [cond, then_v]}, query) do
    with {:ok, q1, cc} <- translate(cond, query),
         {:ok, q2, tc} <- translate(then_v, q1) do
      {:ok, q2, "CASE WHEN #{cc} THEN #{tc} END"}
    end
  end

  # is_nil(x) → (x IS NULL).
  def translate(%Ash.Query.Function.IsNil{arguments: [inner]}, query) do
    with {:ok, q, c} <- translate(inner, query), do: {:ok, q, "(#{c} IS NULL)"}
  end

  # type(expr, T, constraints) — Ash wraps EVERY expression calculation's body (and an explicit
  # `type/3` cast) in a Type coercion to the declared type; `Ash.Resource.Calculation.expression/3`
  # therefore hands the calc-Ref clause a Type-topped tree, not the bare expression. ArcadeDB is
  # dynamically typed and the inner translation already yields the correct runtime scalar (Div forces
  # toFloat; +/-/* stay numeric; concat stays string), so translate the inner expression and DROP the
  # cast. Value-free on failure — the inner recurse re-applies every Ref/aggregate/sensitive guard.
  def translate(%Ash.Query.Function.Type{arguments: [inner | _]}, query),
    do: translate(inner, query)

  # Single-argument string/math functions with a 1:1 ArcadeDB mapping.
  def translate(%mod{arguments: [inner]}, query) when is_map_key(@unary_fns, mod) do
    with {:ok, q, c} <- translate(inner, query),
         do: {:ok, q, "#{Map.fetch!(@unary_fns, mod)}(#{c})"}
  end

  # Two-argument string-match functions (value context) → CONTAINS / STARTS WITH / ENDS WITH.
  def translate(%mod{arguments: [subject, pattern]}, query) when is_map_key(@match_fns, mod) do
    with {:ok, q1, sc} <- translate(subject, query),
         {:ok, q2, pc} <- translate(pattern, q1) do
      {:ok, q2, "(#{sc} #{Map.fetch!(@match_fns, mod)} #{pc})"}
    end
  end

  # A bare literal → bound $param (never interpolated).
  def translate(value, query) when not is_struct(value) do
    {q, ref} = Query.add_param(query, value)
    {:ok, q, ref}
  end

  # Anything else (an un-mapped operator/function) → unsupported value-free.
  def translate(other, _query), do: {:error, unsupported(shape(other), nil)}

  defp binary(query, l, r, op) do
    with {:ok, q1, lc} <- translate(l, query),
         {:ok, q2, rc} <- translate(r, q1) do
      {:ok, q2, "(#{lc} #{op} #{rc})"}
    end
  end

  # Shared value-Ref guard: stored & not sensitive (Info.value_translatable_field?/2) AND
  # range-comparable storage (rejects :binary base64 + :decimal exact-string — Cypher value ops
  # over either are wrong; D27). Ash already type-checks operands per operator (Plus→numbers,
  # Concat→strings), so this need not re-check numeric-vs-string.
  # `value_translatable_field?`/`stored_field?` RAISE on a non-arcade / nil resource, and translate is
  # reachable with a resource-less query (a changeset_where pre-thread, a bare test fixture) — so mirror
  # `Filter.filterable_field?/2`'s fail-safe: an unknown resource is not rejected (the write path threads
  # the real resource, where the guard actually fires). Never raises (value-free).
  defp ref_ok?(resource, %Ash.Resource.Attribute{name: name, type: type, constraints: constraints}) do
    not (is_atom(resource) and not is_nil(resource) and Ash.Resource.Info.resource?(resource)) or
      (Info.value_translatable_field?(resource, name) and
         Cast.range_comparable?(type, constraints))
  end

  defp unsupported(op, field), do: UnsupportedFilter.exception(operator: op, field: field)

  # Field NAME only from a Ref's attribute (value-free): an attribute struct's name, a bare atom
  # name, or nil for anything else (a Calculation/Aggregate carries no plain field name here).
  defp ref_field_name(%Ash.Resource.Attribute{name: name}), do: name
  defp ref_field_name(name) when is_atom(name), do: name
  defp ref_field_name(_), do: nil

  defp shape(%mod{}), do: mod
  defp shape(_), do: :unsupported_expression
end
