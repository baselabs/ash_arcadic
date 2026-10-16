defmodule AshArcadic.Replicant.Verifiers.ValidateArcadeDataLayer do
  @moduledoc """
  Compile-verifier for a `replicant` CDC mirror target: the resource's data layer must be
  `AshArcadic.DataLayer` (build-blocking under `--warnings-as-errors`).

  The sink applies mirrored writes through AshArcadic's own write machinery
  (`DataLayer.base_write_conn` and the lazily-opened single-session transaction the
  watermark co-commits through). A resource that extends `AshArcadic.Replicant` on a
  DIFFERENT data layer compiles clean today and fails only at sink runtime, scrubbed to a
  generic `:sink_failed` — a delayed, under-specified failure for a statically decidable
  misconfiguration (review note 2026-10-16). This verifier rejects it at compile with the
  remedy in the message.
  """
  use Spark.Dsl.Verifier
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshArcadic.DataLayer
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    case ResourceInfo.data_layer(module) do
      DataLayer ->
        :ok

      other ->
        {:error,
         DslError.exception(
           module: module,
           path: [:replicant],
           message:
             "a `replicant` mirror target must use the AshArcadic data layer (got " <>
               "#{inspect(other)}): the CDC sink mirrors rows through AshArcadic's own " <>
               "write machinery — `use Ash.Resource, data_layer: AshArcadic.DataLayer`."
         )}
    end
  end
end
