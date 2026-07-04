defmodule AshArcadic.Multitenancy do
  @moduledoc """
  Resolves the ArcadeDB **database name** for a `:context`-multitenant resource +
  tenant. The name reaches a URL path, so it must be a valid `Arcadic.Identifier`
  (letter-first, ≤128 bytes), injective (distinct tenants → distinct databases — a
  hard isolation invariant), and deterministic.

  Default two-branch encoder:
    * **passthrough** — a tenant whose stringified form is `[A-Za-z0-9_]+` becomes
      `"t_" <> tenant` (the `t_` supplies the letter start; a leading digit is fine).
      Keeps ULID/integer/slug tenants readable.
    * **encode** — anything else becomes `"g" <> Base.encode32(tenant, :lower, no-pad)`;
      alphabet `[a-z2-7]`, the `g` guarantees a letter start.

  Branch A always starts `t`, branch B always starts `g` → disjoint namespaces;
  each branch is a constant prefix over an injective input. Anything that will not
  fit 128 bytes fails **closed** with a value-free error (steer to `tenant_database`).

  The encoder keys on `to_string(tenant)`, so distinct tenant terms that share a
  string form collide — integer `42` and string `"42"` both map to `"t_42"`. This is
  harmless in a homogeneous tenant space; a space that mixes term types for the same
  logical tenant must set `tenant_database` to disambiguate. The default also assumes
  a `String.Chars` tenant: a non-`String.Chars` term (tuple/map/struct) raises rather
  than encoding — steer such tenants through `tenant_database`.

  NOTE: the derived name is operator-visible (server logs, `Arcadic.Server.list_databases`).
  The passthrough branch echoes the tenant id into that surface — a tenant space whose
  id is itself classified should set `tenant_database` to hash it (see usage-rules).
  """
  alias AshArcadic.DataLayer.Info

  @max_bytes 128
  @identifier_body ~r/\A[A-Za-z0-9_]+\z/
  @identifier_full ~r/\A[A-Za-z][A-Za-z0-9_]*\z/

  @doc "The ArcadeDB database name for `resource` + `tenant`, or a value-free raise (fail-closed)."
  @spec database_name(Ash.Resource.t(), term()) :: String.t()
  def database_name(resource, tenant) do
    case Info.tenant_database(resource) do
      nil -> default_encode(tenant)
      {m, f, a} -> validate_mfa!(apply(m, f, [tenant | a]))
    end
  end

  defp default_encode(tenant) do
    str = to_string(tenant)
    passthrough = "t_" <> str

    cond do
      str == "" ->
        fail_closed!()

      Regex.match?(@identifier_body, str) and byte_size(passthrough) <= @max_bytes ->
        passthrough

      true ->
        encoded = "g" <> Base.encode32(str, case: :lower, padding: false)
        if byte_size(encoded) <= @max_bytes, do: encoded, else: fail_closed!()
    end
  end

  defp validate_mfa!(name) when is_binary(name) do
    if Regex.match?(@identifier_full, name) and byte_size(name) <= @max_bytes do
      name
    else
      raise ArgumentError,
            "the tenant_database MFA returned an invalid or too-long identifier (value redacted)"
    end
  end

  defp validate_mfa!(_),
    do: raise(ArgumentError, "the tenant_database MFA must return a String identifier")

  defp fail_closed! do
    raise ArgumentError,
          "could not derive a valid ArcadeDB database identifier for the tenant within " <>
            "#{@max_bytes} bytes (tenant value redacted); configure a `tenant_database` MFA"
  end
end
