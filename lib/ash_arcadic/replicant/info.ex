defmodule AshArcadic.Replicant.Info do
  @moduledoc """
  Introspection for the `replicant do ... end` `AshArcadic.Replicant` extension.

  Generates the `replicant_<option>/1` (`{:ok, value} | :error`) and
  `replicant_<option>!/1` accessors for every option, plus the hand-written
  helpers below: `source_table/1` (the declared value — required, no
  reflection fallback), `source_schema/1` (declared value, else `"public"`),
  `tenant_attribute/1`, `skip/1`, and `on_truncate/1`.
  """
  use Spark.InfoGenerator, extension: AshArcadic.Replicant, sections: [:replicant]

  @doc "The source Postgres table for the resource. Required — no reflection fallback."
  @spec source_table(Ash.Resource.t()) :: String.t()
  def source_table(resource), do: replicant_source_table!(resource)

  @doc "The source Postgres schema for the resource: the explicit `source_schema`, else \"public\"."
  @spec source_schema(Ash.Resource.t()) :: String.t()
  def source_schema(resource), do: replicant_source_schema!(resource)

  @doc "The source column carrying the tenant, else `nil` when undeclared."
  @spec tenant_attribute(Ash.Resource.t()) :: atom() | nil
  def tenant_attribute(resource) do
    case replicant_tenant_attribute(resource) do
      {:ok, attribute} -> attribute
      :error -> nil
    end
  end

  @doc "Source columns excluded from the mirror write, else `[]` when undeclared."
  @spec skip(Ash.Resource.t()) :: [atom()]
  def skip(resource), do: replicant_skip!(resource)

  @doc "The upstream TRUNCATE policy: `:halt` (default, fail-closed) or `:mirror`."
  @spec on_truncate(Ash.Resource.t()) :: :halt | :mirror
  def on_truncate(resource), do: replicant_on_truncate!(resource)
end
