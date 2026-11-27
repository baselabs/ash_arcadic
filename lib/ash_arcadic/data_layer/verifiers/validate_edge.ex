defmodule AshArcadic.DataLayer.Verifiers.ValidateEdge do
  @moduledoc """
  Build-blocking compile verifier: an `edge`'s `label` or any `properties` key that
  is not a valid `Arcadic.Identifier` raises a `Spark.Error.DslError` (surfaced as a
  compiler diagnostic under `--warnings-as-errors`). Edge labels are interpolated
  into Cypher (`MERGE (a)-[e:LABEL]->(b)`) and property keys into `SET e.<key>`, so
  both are validated at declaration time.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:arcade])
    |> Enum.filter(&match?(%AshArcadic.Edge{}, &1))
    |> Enum.reduce_while(:ok, fn edge, :ok ->
      case validate(edge) do
        :ok ->
          {:cont, :ok}

        {:error, message} ->
          {:halt,
           {:error,
            DslError.exception(
              module: Verifier.get_persisted(dsl_state, :module),
              path: [:arcade, :edge, edge.name],
              message: message
            )}}
      end
    end)
  end

  defp validate(edge) do
    case Enum.find([edge.label | edge.properties], &(not valid_identifier?(&1))) do
      nil ->
        validate_identity(edge)

      bad ->
        {:error,
         "edge #{inspect(edge.name)} has an invalid ArcadeDB identifier #{inspect(bad)}. " <>
           "Must start with a letter, then letters/digits/underscores, ≤128 bytes."}
    end
  end

  defp validate_identity(%{identity: []}), do: :ok

  defp validate_identity(edge) do
    if not edge.multiple? and Enum.uniq(edge.identity) == edge.identity and
         Enum.all?(edge.identity, &(&1 in edge.properties)) do
      :ok
    else
      {:error,
       "edge identity must list distinct declared properties and requires multiple? false"}
    end
  end

  defp valid_identifier?(atom) when is_atom(atom),
    do: Arcadic.Identifier.valid?(Atom.to_string(atom))
end
