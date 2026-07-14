defmodule AshArcadic.DataLayer.Verifiers.ValidateVectorIndex do
  @moduledoc """
  Compile-verifier for `arcade do vector_index … end` (build-blocking under
  `--warnings-as-errors`). Each declared `vector_index` `name` must be:

  - **V1** — a STORED attribute: declared AND not in `skip`. A skipped attribute is
    never persisted as an ArcadeDB property, so an index over it would target nothing.
  - **V2** — NOT `sensitive` (AGENTS.md Rule 3): a vector index is an `ARRAY_OF_FLOATS`
    property; a `sensitive` attribute must be encrypted-binary, which cannot be a
    float-array index (and AshArcadic holds no key material). The two are mutually
    exclusive by construction.
  - **V3** — array-typed (best-effort): a scalar-typed attribute cannot hold an
    embedding. Checks the type SHAPE, not the values.
  - **V4** — a unique `name` (a duplicate declaration is a config error).

  `dimensions`/`similarity` are validated by the entity schema itself (Spark).
  Value-free: messages carry the attribute NAME (developer config, not row data),
  never a value.
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    case Verifier.get_entities(dsl_state, [:arcade]) do
      entities ->
        indexes = Enum.filter(entities, &match?(%AshArcadic.VectorIndex{}, &1))
        if indexes == [], do: :ok, else: do_verify(dsl_state, indexes)
    end
  end

  defp do_verify(dsl_state, indexes) do
    module = Verifier.get_persisted(dsl_state, :module)
    skip = Verifier.get_option(dsl_state, [:arcade], :skip, [])
    sensitive = Verifier.get_option(dsl_state, [:arcade], :sensitive, [])
    attrs = Verifier.get_entities(dsl_state, [:attributes])
    by_name = Map.new(attrs, &{&1.name, &1})

    with :ok <- unique_names(module, indexes) do
      each_index(module, indexes, by_name, skip, sensitive)
    end
  end

  defp unique_names(module, indexes) do
    dups =
      indexes
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    case dups do
      [] ->
        :ok

      names ->
        {:error,
         DslError.exception(
           module: module,
           path: [:arcade, :vector_index],
           message: "duplicate `vector_index` name(s) #{inspect(names)}; each must be unique."
         )}
    end
  end

  defp each_index(module, indexes, by_name, skip, sensitive) do
    Enum.reduce_while(indexes, :ok, fn index, :ok ->
      case verify_index(module, index, by_name, skip, sensitive) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_index(module, %{name: name}, by_name, skip, sensitive) do
    cond do
      not Map.has_key?(by_name, name) ->
        fail(module, "#{inspect(name)} is not a declared attribute (a typo indexes nothing).")

      name in skip ->
        fail(
          module,
          "#{inspect(name)} is in `skip`, so it is never stored as an ArcadeDB property — " <>
            "a vector index over it would target nothing."
        )

      name in sensitive ->
        fail(
          module,
          "#{inspect(name)} is `sensitive`, so it must be encrypted-binary (Rule 3) and cannot " <>
            "be a float-array vector index. A vector-indexed property is plaintext by design."
        )

      not array_typed?(Map.fetch!(by_name, name)) ->
        fail(
          module,
          "#{inspect(name)} is not array-typed; a vector index requires an array attribute " <>
            "(e.g. `{:array, :float}`) to hold the embedding."
        )

      true ->
        :ok
    end
  end

  # Best-effort array-shape check. Ash normalizes `{:array, :float}` to `{:array, Ash.Type.Float}`;
  # the outer tuple match holds regardless of inner normalization.
  defp array_typed?(%{type: {:array, _}}), do: true
  defp array_typed?(_attr), do: false

  defp fail(module, message) do
    {:error, DslError.exception(module: module, path: [:arcade, :vector_index], message: message)}
  end
end
