defmodule AshArcadic.DataLayer.Verifiers.ValidateLabelFormat do
  @moduledoc false
  # Validates the (possibly EnsureLabelled-defaulted) label is a valid ArcadeDB
  # identifier. Runs after all transformers, so it sees the defaulted value.
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    label = Verifier.get_option(dsl_state, [:arcade], :label)

    if is_nil(label) or Arcadic.Identifier.valid?(to_string(label)) do
      :ok
    else
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl_state, :module),
         path: [:arcade, :label],
         message:
           "Invalid label #{inspect(label)}: must be a valid ArcadeDB identifier " <>
             "(start with a letter, then letters/digits/underscores, ≤128 bytes)."
       )}
    end
  end
end
