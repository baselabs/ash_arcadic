defmodule AshArcadic.DataLayer.Info do
  @moduledoc "Introspection for the `arcade do … end` DSL section."
  alias Ash.Resource.Info, as: ResourceInfo
  alias Spark.Dsl.Extension

  @spec client(Ash.Resource.t()) :: module() | nil
  def client(resource), do: Extension.get_opt(resource, [:arcade], :client)

  @spec database(Ash.Resource.t()) :: String.t() | nil
  def database(resource), do: Extension.get_opt(resource, [:arcade], :database)

  @spec label(Ash.Resource.t()) :: atom() | String.t()
  def label(resource),
    do: Extension.get_opt(resource, [:arcade], :label) || default_label(resource)

  @spec skip(Ash.Resource.t()) :: [atom()]
  def skip(resource), do: Extension.get_opt(resource, [:arcade], :skip, [])

  @spec sensitive(Ash.Resource.t()) :: [atom()]
  def sensitive(resource), do: Extension.get_opt(resource, [:arcade], :sensitive, [])

  @spec tenant_database(Ash.Resource.t()) :: {module(), atom(), list()} | nil
  def tenant_database(resource), do: Extension.get_opt(resource, [:arcade], :tenant_database, nil)

  @spec attribute_map(Ash.Resource.t()) :: %{atom() => String.t()}
  def attribute_map(resource) do
    skip = skip(resource)

    resource
    |> ResourceInfo.attributes()
    |> Enum.reject(&(&1.name in skip))
    |> Map.new(&{&1.name, Atom.to_string(&1.name)})
  end

  @spec attribute_types(Ash.Resource.t()) :: %{atom() => {Ash.Type.t(), keyword()}}
  def attribute_types(resource) do
    resource
    |> ResourceInfo.attributes()
    |> Map.new(&{&1.name, {&1.type, &1.constraints}})
  end

  defp default_label(resource), do: resource |> Module.split() |> List.last()
end
