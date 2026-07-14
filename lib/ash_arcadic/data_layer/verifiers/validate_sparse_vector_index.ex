defmodule AshArcadic.DataLayer.Verifiers.ValidateSparseVectorIndex do
  @moduledoc """
  Compile-verifier for `arcade do sparse_vector_index … end` (build-blocking under
  `--warnings-as-errors`). A sparse index declares a `(tokens, weights)` attribute PAIR; BOTH
  attributes must be:

  - **V1** — a STORED attribute: declared AND not in `skip` (a skipped attribute is never
    persisted as an ArcadeDB property, so an index over it would target nothing).
  - **V2** — NOT `sensitive` (AGENTS.md Rule 3): a sparse index property is a plaintext numeric
    array; a `sensitive` attribute must be encrypted-binary, which cannot be an array index.
  - **V3** — array-typed (best-effort): tokens must be an integer array, weights a float array;
    a scalar-typed attribute cannot hold a sparse-vector component. Checks the type SHAPE.

  Plus: **V4** — a unique `name`, across BOTH `sparse_vector_index` AND `vector_index` names (a
  collision means a vector-search preparation could not disambiguate); and `tokens` and `weights`
  must be DISTINCT attributes (the same attribute cannot be both slots).

  Value-free: messages carry the attribute/index NAME (developer config, not row data), never a value.
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    sparse =
      dsl_state
      |> Verifier.get_entities([:arcade])
      |> Enum.filter(&match?(%AshArcadic.SparseVectorIndex{}, &1))

    if sparse == [], do: :ok, else: do_verify(dsl_state, sparse)
  end

  defp do_verify(dsl_state, sparse) do
    module = Verifier.get_persisted(dsl_state, :module)
    skip = Verifier.get_option(dsl_state, [:arcade], :skip, [])
    sensitive = Verifier.get_option(dsl_state, [:arcade], :sensitive, [])
    attrs = Verifier.get_entities(dsl_state, [:attributes])
    by_name = Map.new(attrs, &{&1.name, &1})

    dense_names =
      dsl_state
      |> Verifier.get_entities([:arcade])
      |> Enum.filter(&match?(%AshArcadic.VectorIndex{}, &1))
      |> Enum.map(& &1.name)

    with :ok <- unique_names(module, sparse, dense_names) do
      each_index(module, sparse, by_name, skip, sensitive)
    end
  end

  # Duplicate across sparse-vs-sparse AND sparse-vs-dense: a preparation referencing that name
  # could resolve to either declaration.
  defp unique_names(module, sparse, dense_names) do
    sparse_names = Enum.map(sparse, & &1.name)

    dup_sparse =
      sparse_names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    collide = sparse_names |> Enum.uniq() |> Enum.filter(&(&1 in dense_names))

    cond do
      dup_sparse != [] ->
        fail(
          module,
          "duplicate `sparse_vector_index` name(s) #{inspect(dup_sparse)}; each must be unique."
        )

      collide != [] ->
        fail(
          module,
          "`sparse_vector_index` name(s) #{inspect(collide)} collide with a `vector_index` of the " <>
            "same name; index names must be unique across dense and sparse."
        )

      true ->
        :ok
    end
  end

  defp each_index(module, sparse, by_name, skip, sensitive) do
    Enum.reduce_while(sparse, :ok, fn index, :ok ->
      case verify_index(module, index, by_name, skip, sensitive) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_index(
         module,
         %{name: name, tokens: tokens, weights: weights},
         by_name,
         skip,
         sensitive
       ) do
    if tokens == weights do
      fail(
        module,
        "sparse_vector_index #{inspect(name)} must use DISTINCT `tokens` and `weights` attributes " <>
          "(both were #{inspect(tokens)})."
      )
    else
      with :ok <- verify_attr(module, name, :tokens, tokens, by_name, skip, sensitive) do
        verify_attr(module, name, :weights, weights, by_name, skip, sensitive)
      end
    end
  end

  defp verify_attr(module, name, slot, attr_name, by_name, skip, sensitive) do
    prefix = "sparse_vector_index #{inspect(name)} #{slot} #{inspect(attr_name)}"

    cond do
      not Map.has_key?(by_name, attr_name) ->
        fail(module, "#{prefix} is not a declared attribute (a typo indexes nothing).")

      attr_name in skip ->
        fail(
          module,
          "#{prefix} is in `skip`, so it is never stored as an ArcadeDB property — a sparse index " <>
            "over it would target nothing."
        )

      attr_name in sensitive ->
        fail(
          module,
          "#{prefix} is `sensitive`, so it must be encrypted-binary (Rule 3) and cannot be a " <>
            "plaintext numeric-array sparse-index component."
        )

      not array_typed?(Map.fetch!(by_name, attr_name)) ->
        fail(
          module,
          "#{prefix} is not array-typed; a sparse index requires array attributes " <>
            "(tokens `{:array, :integer}`, weights `{:array, :float}`)."
        )

      true ->
        :ok
    end
  end

  # Best-effort array-shape check. Ash normalizes `{:array, :integer}` to `{:array, Ash.Type.Integer}`;
  # the outer tuple match holds regardless of inner normalization.
  defp array_typed?(%{type: {:array, _}}), do: true
  defp array_typed?(_attr), do: false

  defp fail(module, message) do
    {:error,
     DslError.exception(module: module, path: [:arcade, :sparse_vector_index], message: message)}
  end
end
