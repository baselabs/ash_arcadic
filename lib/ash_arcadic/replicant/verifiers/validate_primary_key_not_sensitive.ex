defmodule AshArcadic.Replicant.Verifiers.ValidatePrimaryKeyNotSensitive do
  @moduledoc """
  Compile-verifier for a `replicant` CDC mirror target's primary key
  (build-blocking under `--warnings-as-errors`).

  The mirror's primary key is the identity the sink MATCHes on (`upsert_identity`
  for idempotent re-delivery, and the by-PK destroy). The sink builds it from the
  SOURCE (Postgres) row's plaintext key columns (`Resolver.pk_values/2`), which —
  unlike `writable_target`/`attrs_for_upsert` — do NOT pass through the F5
  sensitive-halt guard, because the identity must be a plaintext value to match.

  So a primary-key attribute declared `arcade do sensitive ... end` is
  contradictory and unsafe: AshArcadic holds no key material, so the sink would
  write the source's PLAINTEXT key into a column the classification says must hold
  encrypted bytes — leaking the classified datum AND breaking idempotent matching
  (an encrypted-at-rest identity can never equal a plaintext lookup). This verifier
  rejects it at compile, fail-closed, mirroring `ValidateSensitive`'s R3 rule that
  the multitenancy discriminator (also a plaintext selector) cannot be sensitive.

  The remedy is to model the mirror identity as a non-sensitive key (the source PK
  is already a plaintext natural/surrogate key upstream).
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    sensitive = Verifier.get_option(dsl_state, [:arcade], :sensitive, [])

    offending =
      dsl_state
      |> Verifier.get_entities([:attributes])
      |> Enum.find(&(&1.primary_key? and &1.name in sensitive))

    case offending do
      nil ->
        :ok

      attr ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:arcade, :sensitive],
           message:
             "the primary-key attribute #{inspect(attr.name)} of a `replicant` mirror " <>
               "cannot be `sensitive`: the sink builds the mirror identity from the source " <>
               "row's PLAINTEXT key to MATCH the vertex (upsert/destroy), and AshArcadic holds " <>
               "no key to encrypt it — so a sensitive PK would leak the classified value into " <>
               "the identity AND break idempotent matching. Model the identity as a " <>
               "non-sensitive key (mirroring the R3 rule that the tenant discriminator " <>
               "cannot be sensitive)."
         )}
    end
  end
end
