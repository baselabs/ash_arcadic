defmodule AshArcadic.DataLayer.Verifiers.ValidateRelationshipFk do
  @moduledoc """
  Compile-verifier (build-blocking under `--warnings-as-errors`): a relationship's LOCAL join
  attribute must not be `sensitive`. A sensitive attribute is app-side-encrypted binary
  (`ValidateSensitive` R2); an encrypted-binary FK cannot be `IN`-joined — Slice-5 relationship
  loading builds `dest.<fk> IN [<plaintext pks>]`, so a sensitive join key silently breaks loading
  and leaks via filter presence/absence. Fail closed, value-free (names the attribute atom only).

  Each FK is LOCAL to exactly one resource (the resource that declares it as an attribute), so
  checking every resource's join attributes that are in ITS OWN attribute set covers all positions —
  including `many_to_many` through-resource FKs, which are checked by the join resource's own verifier.
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    case Verifier.get_option(dsl_state, [:arcade], :sensitive, []) do
      [] -> :ok
      sensitive -> do_verify(dsl_state, MapSet.new(sensitive))
    end
  end

  defp do_verify(dsl_state, sensitive) do
    module = Verifier.get_persisted(dsl_state, :module)
    local = dsl_state |> Verifier.get_entities([:attributes]) |> MapSet.new(& &1.name)

    dsl_state
    |> Verifier.get_entities([:relationships])
    |> Enum.reduce_while(:ok, fn rel, :ok ->
      case offending_join_attr(rel, sensitive, local) do
        nil -> {:cont, :ok}
        attr -> {:halt, reject(module, rel.name, attr)}
      end
    end)
  end

  # Join attributes that live ON this resource (present in `local`) AND are declared `sensitive`.
  defp offending_join_attr(rel, sensitive, local) do
    [
      Map.get(rel, :source_attribute),
      Map.get(rel, :destination_attribute),
      Map.get(rel, :source_attribute_on_join_resource),
      Map.get(rel, :destination_attribute_on_join_resource)
    ]
    |> Enum.find(fn a ->
      not is_nil(a) and MapSet.member?(local, a) and MapSet.member?(sensitive, a)
    end)
  end

  defp reject(module, rel_name, attr) do
    {:error,
     DslError.exception(
       module: module,
       path: [:relationships, rel_name],
       message:
         "relationship #{inspect(rel_name)} joins on attribute #{inspect(attr)}, which is " <>
           "`sensitive` (app-side-encrypted binary). An encrypted FK cannot be IN-joined and " <>
           "silently breaks relationship loading; a join key must be plaintext. Remove it from " <>
           "`sensitive`, or use a non-sensitive join attribute."
     )}
  end
end
