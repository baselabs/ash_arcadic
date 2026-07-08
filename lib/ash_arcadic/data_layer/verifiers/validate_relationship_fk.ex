defmodule AshArcadic.DataLayer.Verifiers.ValidateRelationshipFk do
  @moduledoc """
  Compile-verifier (build-blocking under `--warnings-as-errors`): a relationship's LOCAL join
  attribute must not be `sensitive`. A sensitive attribute is app-side-encrypted binary
  (`ValidateSensitive` R2); an encrypted-binary FK cannot be `IN`-joined — Slice-5 relationship
  loading builds `dest.<fk> IN [<plaintext pks>]`, so a sensitive join key silently breaks loading
  and leaks via filter presence/absence. Fail closed, value-free (names the attribute atom only).

  ## Coverage boundary (verified at Slice-5 closeout, 2026-07-08)

  This verifier runs per-resource and flags a join attribute only when it is BOTH in the current
  resource's own attribute set (`local`) AND its `sensitive` list. Coverage is therefore per-resource
  and LOCAL:

  - `belongs_to.source_attribute` — local to the source (the FK lives here) → caught directly.
  - `many_to_many` join-resource FKs — local to the JOIN resource, which idiomatically declares them
    as the `source_attribute` of its own `belongs_to` to each endpoint → caught by the JOIN resource's
    own run (NOT by the `*_on_join_resource` slots below, which name attributes remote to the declaring
    resource and so never satisfy the `local` check — they are kept as defensive belt-and-suspenders,
    not the coverage mechanism).

  KNOWN LIMITATION (routed follow-up → Slice 6): a `has_many`/`has_one` `destination_attribute` names an
  attribute on the DESTINATION resource. It is caught here only when the destination independently
  declares a relationship using that attribute as a LOCAL join key (the idiomatic inverse `belongs_to`).
  A `has_many`/`has_one` whose sensitive `destination_attribute` has no such inverse is NOT caught at
  compile (a per-resource Spark verifier cannot read a sibling resource's `sensitive` list without
  compile-ordering fragility). Slice-6 adds a RUNTIME, LOAD-TIME guard (`AshArcadic.Query.Filter`
  rejects a value comparison — including the relationship-load `dest.<fk> IN [pks]` — on a sensitive or
  non-stored field), which converts the residual from a silent-`[]` load into a fail-closed loud
  `%UnsupportedFilter{}`. That guard is load-time, not compile-time: a misconfigured resource still
  compiles clean and fails only when the relationship is loaded.
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
