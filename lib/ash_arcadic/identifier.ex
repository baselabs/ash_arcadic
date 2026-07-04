defmodule AshArcadic.Identifier do
  @moduledoc """
  Identifier validation for values AshArcadic interpolates into Cypher or a
  database name (labels, database names, sort/PK/attribute field names). The
  allowlist is single-sourced in `Arcadic.Identifier` (letter-first, ≤128) — the
  same guard the transport applies — so labels and DB names satisfy the URL-path
  and statement rules by construction. Never interpolate a VALUE; values ride
  `params`. A failure carries the invalid-SHAPE fact only, never the offending
  string (AGENTS.md Rules 1 & 4).
  """

  @doc """
  Returns the identifier as a string, or raises a value-free `ArgumentError`.

  Accepts a non-`nil`, non-boolean atom or a binary. Fails **closed**: `nil`,
  `true`/`false`, and any non-atom/non-binary term raise the same value-free
  `ArgumentError` rather than silently becoming the literal `"nil"`/`"true"` or a
  `FunctionClauseError` that could surface the argument in a stacktrace (AGENTS.md
  Rules 2 & 4). Callers pass DSL-static labels or resolved identifiers, never a
  runtime value.
  """
  @spec validate!(atom() | String.t()) :: String.t()
  def validate!(name) when is_nil(name) or is_boolean(name), do: raise_invalid!()

  def validate!(name) when is_atom(name), do: validate!(Atom.to_string(name))

  def validate!(name) when is_binary(name) do
    case Arcadic.Identifier.validate(name) do
      :ok -> name
      {:error, :invalid_identifier} -> raise_invalid!()
    end
  end

  def validate!(_other), do: raise_invalid!()

  @spec raise_invalid!() :: no_return()
  defp raise_invalid!, do: raise(ArgumentError, "invalid ArcadeDB identifier (value redacted)")
end
