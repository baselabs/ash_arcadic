defmodule AshArcadic.Replicant.Verifiers.ValidateSensitiveSkipped do
  @moduledoc """
  Compile-verifier for a `replicant` CDC mirror target: every `arcade do sensitive … end`
  attribute must be listed in the `replicant do skip … end` list (build-blocking under
  `--warnings-as-errors`).

  The apply path's classify/3 halts the whole delivery (`:sensitive_plaintext`) on the
  first arriving row whose column maps to a non-skipped sensitive attribute: the Postgres
  value is PLAINTEXT and AshArcadic holds no key to encrypt it, so the only fail-closed
  form is refusal. Before this verifier that contradiction — a sensitive attribute the
  sink will inevitably refuse — compiled CLEAN and halted the pipeline at runtime,
  possibly much later (the first row carrying that column; a nullable column can delay
  the halt indefinitely).

  Both lists live in the DSL state at compile, so the rule is statically decidable —
  exactly the shape of the sibling `ValidatePrimaryKeyNotSensitive` /
  `ValidatePrimaryKeyNotSkipped` verifiers. This closes the runtime gap to compile time
  (review catch 2026-10-16).

  The remedy: a sensitive mirror column is either mapped nowhere (dropped — declare it in
  `replicant skip` so the intent is explicit and the runtime halt becomes unreachable) or
  the host app encrypts upstream before the slot delivers it.
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    sensitive = Verifier.get_option(dsl_state, [:arcade], :sensitive, [])
    skip = Verifier.get_option(dsl_state, [:replicant], :skip, [])

    offending = Enum.reject(sensitive, &(&1 in skip))

    case offending do
      [] ->
        :ok

      [first | _] ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:replicant, :skip],
           message:
             "the sensitive attribute #{inspect(first)} is not in the `replicant skip` list: " <>
               "the CDC sink receives PLAINTEXT from the source and AshArcadic holds no key " <>
               "to encrypt it, so the apply path will halt delivery (:sensitive_plaintext) " <>
               "on the first row carrying that column. Add it to `replicant do skip … end` " <>
               "(mirror nothing) or drop the `sensitive` classification."
         )}
    end
  end
end
