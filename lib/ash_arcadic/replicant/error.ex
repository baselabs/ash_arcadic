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
  """
  use Splode.Error, fields: [:reason, :resource, :op], class: :invalid

  @type reason :: :tenant_required | :sensitive_plaintext

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
