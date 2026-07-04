defmodule AshArcadic.Errors.QueryFailed do
  @moduledoc "Error for failed queries/reads/destroys. Carries only query label + structural reason."
  use Splode.Error, fields: [:query, :reason], class: :invalid

  def message(%{query: query, reason: reason}),
    do: "Query failed: #{inspect(query)} - #{inspect(reason)}"
end
