defmodule AshArcadic.Replicant.Verifiers.ValidatePrimaryKeyNotSkipped do
  @moduledoc """
  Compile-verifier for a `replicant` CDC mirror target's primary key
  (build-blocking under `--warnings-as-errors`).

  The mirror's primary key is the identity the sink MATCHes on (the `upsert?: true`
  MERGE identity and the by-PK destroy). The sink builds the write inputs with
  `Resolver.attrs_for_upsert/2`, which DROPS every replicant-`skip` source column.
  The upsert's separate `reject_empty_identity!` guard checks only the RAW source
  record, so a `skip`-listed primary-key column passes that check yet is dropped
  from the write inputs — `Ash.create!(upsert?: true)` then runs WITHOUT the
  identity: a UUID primary key gets a fresh random value on every apply (duplicate
  vertices; a later by-PK destroy can never find them), silently breaking
  effect-once.

  The replicant `skip` list names SOURCE (Postgres) columns, which map 1:1 to the
  target attribute of the same name (there is no rename DSL), so "a primary-key
  attribute's source column is skipped" is statically decidable at compile time:
  **no primary-key attribute's name may appear in the replicant `skip` list.** The
  remedy is to remove the primary key from `skip` (a mirror identity must be
  written to be matchable), mirroring `ValidatePrimaryKeyNotSensitive` — the other
  compile guard on the plaintext mirror identity.
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    skip = Verifier.get_option(dsl_state, [:replicant], :skip, [])

    offending =
      dsl_state
      |> Verifier.get_entities([:attributes])
      |> Enum.find(&(&1.primary_key? and &1.name in skip))

    case offending do
      nil ->
        :ok

      attr ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:replicant, :skip],
           message:
             "the primary-key attribute #{inspect(attr.name)} of a `replicant` mirror " <>
               "must not be in the replicant `skip` list: `attrs_for_upsert/2` drops every " <>
               "skipped column from the write inputs, so the sink would upsert WITHOUT the " <>
               "identity — a UUID key gets a fresh random value each apply (duplicate " <>
               "vertices; deletes can never match). Remove #{inspect(attr.name)} from `skip` " <>
               "(a mirror identity must be written to be matchable)."
         )}
    end
  end
end
