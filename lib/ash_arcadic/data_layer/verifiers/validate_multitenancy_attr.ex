defmodule AshArcadic.DataLayer.Verifiers.ValidateMultitenancyAttr do
  @moduledoc """
  Compile-verifier for `:attribute` multitenancy. Two fail-open holes turned into
  compile errors (AshArcadic has no `rls_guc`; those ash_age clauses are dropped —
  ArcadeDB has no row-level security):

  - the discriminator must not be in `arcade do skip [...]` — a skipped discriminator
    is never written, so the tenant filter Ash injects matches nothing (fail-open).
  - the discriminator must not be binary-storage-typed — it is a plaintext comparator
    across the vertex filter and traversal per-node scoping; a tag/base64 discriminator
    would scope those paths inconsistently.
  """
  use Spark.Dsl.Verifier
  alias AshArcadic.Cast
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    strategy = Verifier.get_option(dsl_state, [:multitenancy], :strategy)
    attribute = Verifier.get_option(dsl_state, [:multitenancy], :attribute)
    skip = Verifier.get_option(dsl_state, [:arcade], :skip, [])
    module = Verifier.get_persisted(dsl_state, :module)

    with :ok <- not_skipped(module, strategy, attribute, skip) do
      not_binary(dsl_state, module, strategy, attribute)
    end
  end

  defp not_skipped(module, :attribute, attribute, skip) do
    if attribute in skip do
      {:error,
       DslError.exception(
         module: module,
         path: [:arcade, :skip],
         message:
           "the multitenancy attribute #{inspect(attribute)} must not appear in " <>
             "`arcade do skip [...]`: the discriminator would never be written, so the tenant " <>
             "filter Ash injects on reads matches nothing (fail-open isolation)."
       )}
    else
      :ok
    end
  end

  defp not_skipped(_module, _strategy, _attribute, _skip), do: :ok

  defp not_binary(dsl_state, module, :attribute, attribute) do
    binary? =
      dsl_state
      |> Verifier.get_entities([:attributes])
      |> Enum.find(&(&1.name == attribute))
      |> case do
        nil -> false
        attr -> Cast.binary_storage?(attr.type, attr.constraints)
      end

    if binary? do
      {:error,
       DslError.exception(
         module: module,
         path: [:multitenancy, :attribute],
         message:
           "the multitenancy attribute #{inspect(attribute)} must not be binary-storage-" <>
             "typed: the discriminator is a plaintext comparator across the vertex filter and " <>
             "traversal per-node scoping; a tag/base64 discriminator would scope inconsistently."
       )}
    else
      :ok
    end
  end

  defp not_binary(_dsl_state, _module, _strategy, _attribute), do: :ok
end
