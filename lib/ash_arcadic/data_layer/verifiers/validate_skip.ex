defmodule AshArcadic.DataLayer.Verifiers.ValidateSkip do
  @moduledoc """
  Compile-verifier: a primary-key attribute must not appear in `arcade do skip [...] end`.
  A skipped PK is never written as a property, so every update/destroy MATCH on the
  full primary key matches zero rows (perpetual StaleRecord) and reads decode a nil PK.

  Spark surfaces the failure as a compiler diagnostic — build-blocking under
  `--warnings-as-errors`, with no runtime signal.
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    skip = Verifier.get_option(dsl_state, [:arcade], :skip, [])

    pk_in_skip =
      dsl_state
      |> Verifier.get_entities([:attributes])
      |> Enum.filter(& &1.primary_key?)
      |> Enum.map(& &1.name)
      |> Enum.filter(&(&1 in skip))

    case pk_in_skip do
      [] ->
        :ok

      bad ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:arcade, :skip],
           message:
             "primary key attribute(s) #{inspect(bad)} must not be in `skip`: the PK " <>
               "property would never be written, so every update/destroy matches zero rows " <>
               "(perpetual StaleRecord) and reads decode a nil primary key."
         )}
    end
  end
end
