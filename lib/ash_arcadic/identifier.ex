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
  Accepts an atom or binary.
  """
  @spec validate!(atom() | String.t()) :: String.t()
  def validate!(name) when is_atom(name), do: validate!(Atom.to_string(name))

  def validate!(name) when is_binary(name) do
    case Arcadic.Identifier.validate(name) do
      :ok ->
        name

      {:error, :invalid_identifier} ->
        raise ArgumentError, "invalid ArcadeDB identifier (value redacted)"
    end
  end
end
