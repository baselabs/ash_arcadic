defmodule AshArcadic.Replicant.Verifiers.ValidateWriteActionsAuthorized do
  @moduledoc """
  Compile-verifier for a `replicant` CDC mirror target's write-action seam-lock
  (build-blocking under `--warnings-as-errors`).

  A replicant's effect-once guarantee depends on ordinary writes being impossible:
  create/update/destroy actions must be forbidden by default, so only the CDC sink
  writes — bypassing the whole authorizer with `authorize?: false`. That "forbidden
  by default" property is what an authorizer (canonically `Ash.Policy.Authorizer`
  with a forbidding policy, e.g. `forbid_if always()`) provides; without ANY
  authorizer a plain `Ash.create/update/destroy` is ungated and the seam-lock is
  absent.

  This verifier enforces the **necessary precondition** that is soundly decidable at
  compile time: **a replicant resource that declares any create/update/destroy action
  must declare at least one authorizer.** A read-only replicant resource (no write
  actions) passes vacuously.

  It deliberately does NOT attempt to prove full "forbidden by default" over the
  policy set. Whether a given actor can pass the policies is resolved at runtime by
  the authorizer via SAT over actor-dependent facts (and the domain's `authorize`
  configuration), which a resource verifier — with no actor and no domain in view —
  cannot soundly decide. A pattern-match on the canonical `forbid_if always()` would
  also be unsound: an authorizer with only read policies already forbids writes by
  default (no matching policy => forbidden), and `authorize_if never()`,
  `forbid_unless`, or a custom authorizer are equally valid seam-locks — rejecting
  those would over-reject legitimate resources. So the runtime seam-lock stays a
  runtime guarantee; this check catches only the "forgot to gate the mirror action
  at all" failure, at compile time.
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @write_action_types [:create, :update, :destroy]

  @impl true
  def verify(dsl_state) do
    write_actions =
      dsl_state
      |> Verifier.get_entities([:actions])
      |> Enum.filter(&(&1.type in @write_action_types))

    authorizers = Verifier.get_persisted(dsl_state, :authorizers) || []

    if write_actions == [] or authorizers != [] do
      :ok
    else
      unlocked = Enum.map(write_actions, & &1.name)

      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl_state, :module),
         path: [:actions],
         message:
           "a `replicant` resource with write action(s) #{inspect(unlocked)} declares no " <>
             "authorizer, so those actions are ungated and the effect-once seam-lock is " <>
             "absent: any caller could write the mirror directly, not just the CDC sink. " <>
             "Add an authorizer (e.g. `authorizers: [Ash.Policy.Authorizer]`) that forbids " <>
             "the write actions by default (e.g. `forbid_if always()`); the sink bypasses it " <>
             "with `authorize?: false`."
       )}
    end
  end
end
