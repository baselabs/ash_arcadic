defmodule AshArcadic.DataLayer.Verifiers.ValidateSensitive do
  @moduledoc """
  Compile-verifier for `arcade do sensitive [...] end` (build-blocking under
  `--warnings-as-errors`):

  - **R1** — every listed name is a declared attribute (a typo protects nothing).
  - **R2** — every sensitive attribute is binary-storage-typed (app-side-encrypted
    bytes) or listed in `skip` (never written to the graph).
  - **R3** — the multitenancy discriminator is not sensitive (it is a plaintext
    selector; Ash injects it as a plaintext filter/force-set, and AshArcadic holds
    no key material to encrypt it).

  Checks the TYPE SHAPE, not encryption. (R4 edge-property enforcement is Slice 2.)
  """
  use Spark.Dsl.Verifier
  alias AshArcadic.Cast
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    case Verifier.get_option(dsl_state, [:arcade], :sensitive, []) do
      [] -> :ok
      sensitive -> do_verify(dsl_state, sensitive)
    end
  end

  defp do_verify(dsl_state, sensitive) do
    module = Verifier.get_persisted(dsl_state, :module)
    skip = Verifier.get_option(dsl_state, [:arcade], :skip, [])
    attrs = Verifier.get_entities(dsl_state, [:attributes])
    by_name = Map.new(attrs, &{&1.name, &1})
    tenant_attr = Verifier.get_option(dsl_state, [:multitenancy], :attribute)

    with :ok <- known(module, sensitive, by_name),
         :ok <- not_discriminator(module, sensitive, tenant_attr) do
      encrypted_or_skipped(module, sensitive, by_name, skip)
    end
  end

  defp known(module, sensitive, by_name) do
    case Enum.reject(sensitive, &Map.has_key?(by_name, &1)) do
      [] ->
        :ok

      unknown ->
        {:error,
         DslError.exception(
           module: module,
           path: [:arcade, :sensitive],
           message:
             "#{inspect(unknown)} in `sensitive` is not a declared attribute. " <>
               "A typo here silently protects nothing, so it fails closed."
         )}
    end
  end

  defp not_discriminator(_module, _sensitive, nil), do: :ok

  defp not_discriminator(module, sensitive, tenant_attr) do
    if tenant_attr in sensitive do
      {:error,
       DslError.exception(
         module: module,
         path: [:arcade, :sensitive],
         message:
           "the multitenancy attribute #{inspect(tenant_attr)} cannot be `sensitive`: " <>
             "it is a plaintext selector by design (Ash injects it as a plaintext filter and " <>
             "force-set; AshArcadic holds no key material to encrypt it)."
       )}
    else
      :ok
    end
  end

  defp encrypted_or_skipped(module, sensitive, by_name, skip) do
    offender =
      Enum.find(sensitive, fn name ->
        attr = Map.fetch!(by_name, name)
        name not in skip and not Cast.binary_storage?(attr.type, attr.constraints)
      end)

    case offender do
      nil ->
        :ok

      name ->
        {:error,
         DslError.exception(
           module: module,
           path: [:arcade, :sensitive],
           message:
             "sensitive attribute #{inspect(name)} must be binary-storage-typed or listed " <>
               "in `skip`. A sensitive attribute stored as plaintext defeats the classification; " <>
               "store app-side-encrypted bytes in a :binary-typed attribute, or skip it."
         )}
    end
  end
end
