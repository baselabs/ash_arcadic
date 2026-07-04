defmodule AshArcadic.Errors.UnsupportedFilter do
  @moduledoc """
  Error for a filter operation AshArcadic cannot push down to Cypher. Carries ONLY
  the operator/function module and the referenced field name — the filtered value
  is never captured, so neither the message nor a log line built from it leaks
  PII/secrets (AGENTS.md Rule 4).
  """
  use Splode.Error, fields: [:operator, :field], class: :invalid

  def message(%{operator: operator, field: nil}),
    do: "Unsupported filter operator: #{inspect(operator)}"

  def message(%{operator: operator, field: field}),
    do: "Unsupported filter operator: #{inspect(operator)} on field #{inspect(field)}"
end
