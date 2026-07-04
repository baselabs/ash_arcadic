defmodule AshArcadic.DataLayer.Verifiers.ValidateDatabase do
  @moduledoc false
  # Validates the static `database` option (when present) is a valid ArcadeDB
  # identifier. `:context` tenant databases are validated at resolve time by
  # AshArcadic.Multitenancy; this guards only the DSL-static default.
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    case Verifier.get_option(dsl_state, [:arcade], :database) do
      nil ->
        :ok

      db ->
        if Arcadic.Identifier.valid?(db) do
          :ok
        else
          {:error,
           DslError.exception(
             module: Verifier.get_persisted(dsl_state, :module),
             path: [:arcade, :database],
             message:
               "Invalid database name: must be a valid ArcadeDB identifier " <>
                 "(start with a letter, then letters/digits/underscores, ≤128 bytes)."
           )}
        end
    end
  end
end
