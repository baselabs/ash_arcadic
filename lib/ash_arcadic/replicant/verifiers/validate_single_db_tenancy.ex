defmodule AshArcadic.Replicant.Verifiers.ValidateSingleDbTenancy do
  @moduledoc """
  Compile-verifier for a `replicant` CDC mirror target's multitenancy strategy
  (build-blocking under `--warnings-as-errors`).

  A replicant enforces **effect-once**: an upstream Postgres transaction's writes
  mirror into the graph exactly once, in the same logical transaction. That holds
  only when every tenant a single Postgres transaction can touch lives in ONE
  ArcadeDB database. `:context` multitenancy maps tenants to DIFFERENT ArcadeDB
  databases, so a tenant-blind Postgres transaction's cross-tenant writes would
  span databases and fail `:cross_database_transaction`, shattering effect-once.

  Only `:attribute` (single physical database, tenant is a plaintext discriminator)
  or absent tenancy is permitted on a replicant resource; `:context` is rejected.
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    case Verifier.get_option(dsl_state, [:multitenancy], :strategy) do
      :context ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:multitenancy, :strategy],
           message:
             "a `replicant` resource must not use `:context` multitenancy: a `:context` " <>
               "mirror maps tenants to different ArcadeDB databases, so a tenant-blind " <>
               "Postgres transaction's cross-tenant writes fail `:cross_database_transaction`, " <>
               "shattering effect-once. Use `:attribute` (single-database) tenancy or none."
         )}

      _strategy ->
        :ok
    end
  end
end
