defmodule AshArcadic.Replicant.Error do
  @moduledoc """
  Value-free error for the `AshArcadic.Replicant` sink boundary. Carries STRUCTURE
  only — a `reason` atom, the `resource` module, and the sink `op` — never a source
  row, a column value, or a tenant value.

  The fail-closed halt paths raise this so nothing they refuse to write leaks
  through the exception message (`project_redaction_fail_path_exception_leak`):

    * `:tenant_required` — a row carries no usable tenant (nil / `false` / blank)
      for a resource declaring a `tenant_attribute`, so the mirror write would land
      unscoped (`AshArcadic.Replicant.Resolver.resolve_tenant!/3`).
    * `:sensitive_plaintext` — a non-skipped source column maps to a target
      attribute declared `arcade do sensitive ... end`; the arriving Postgres value
      is plaintext and AshArcadic holds no key to encrypt it, so emitting it would
      write plaintext into a classified column (the F5 runtime guard in
      `writable_target/2` / `attrs_for_upsert/2`).

  The apply step (`AshArcadic.Replicant.Apply`) raises it for the fail-closed
  effect-once paths:

    * `:empty_identity` — an upsert whose primary key resolves to an empty/partial
      identity (missing a PK value) would MERGE on an empty pattern and clobber
      unrelated vertices.
    * `:missing_primary_key` — a delete whose `old_record` lacks a primary-key value
      (would build `id == nil`, matching 0 rows and silently losing the delete).
    * `:truncate_halt` — an upstream TRUNCATE arrived for a resource whose
      `on_truncate` is `:halt` (the fail-closed default).
    * `:unsupported_op` — a change carried an op the invariant map does not cover.
    * `:empty_index` — the sink's resolver index is WHOLESALE empty (no mapped
      resources — empty/wrong domains), so every change would resolve to `nil` and be
      silently dropped WHILE the checkpoint advances (permanent, invisible loss). The
      apply/snapshot paths fail closed on this BEFORE any write, so the checkpoint never
      advances and the transaction is re-delivered. Distinct from a NON-empty index with
      one unmapped table, which is a legitimate partial-publication skip.
    * `:sink_failed` — a mirrored write failed at the data layer; the underlying
      exception is discarded value-free (its contents are never interpolated).

  The pipeline start path raises it for the fail-closed start-mode:

    * `:checkpoint_read_fault` — reading the durable watermark at pipeline start
      faulted, so the checkpoint state is UNKNOWN and no start-mode (snapshot vs
      resume) can be chosen safely. Resuming forward-only on an actually-empty
      checkpoint would skip the required snapshot bootstrap and permanently omit
      every pre-slot row, so a read fault HALTS the start (a transient fault is an
      operator retry), never a silent forward-only (`AshArcadic.Replicant.Pipeline`).

    * `:missing_mirror_action` — a mirror resource declares no primary create /
      destroy action, so the sink's apply path has no writable action to route the
      MERGE upsert / by-PK destroy through. A real mirror MUST be writable; this
      fails closed value-free at the apply seam rather than raising a raw
      `primary_action!` error (`AshArcadic.Replicant.Apply`).
  """
  use Splode.Error, fields: [:reason, :resource, :op], class: :invalid

  @type reason ::
          :tenant_required
          | :sensitive_plaintext
          | :empty_identity
          | :missing_primary_key
          | :truncate_halt
          | :unsupported_op
          | :empty_index
          | :sink_failed
          | :checkpoint_read_fault
          | :missing_mirror_action

  @type t :: %__MODULE__{
          reason: reason() | nil,
          resource: module() | nil,
          op: atom() | nil
        }

  def message(%{reason: reason, resource: resource, op: op}) do
    "ash_arcadic replicant error reason=#{reason} resource=#{inspect(resource)}" <>
      if(op, do: " op=#{inspect(op)}", else: "")
  end
end
