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

  @spec edges(Ash.Resource.t()) :: [AshArcadic.Edge.t()]
  def edges(resource) do
    resource
    |> Extension.get_entities([:arcade])
    |> Enum.filter(&match?(%AshArcadic.Edge{}, &1))
  end

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

  @doc """
  Whether `field` is a STORED ArcadeDB property — a declared attribute NOT in `skip` — and
  thus the only kind of field an `ORDER BY n.<field>` can reference. False for a
  calculation/aggregate NAME (not a declared attribute at all) and for a declared-but-skipped
  attribute (never persisted as a property). Drives the sort-field guard on BOTH the
  record-read sort path (`sort/3`) and the aggregate `:first` sort path: a non-stored sort
  field fails LOUD value-free rather than emitting `ORDER BY` against a non-existent property,
  which ArcadeDB treats as null → a silently arbitrary order.
  """
  @spec sortable_field?(Ash.Resource.t(), atom()) :: boolean()
  def sortable_field?(resource, field) when is_atom(field),
    do: Map.has_key?(attribute_map(resource), field)

  defp default_label(resource), do: resource |> Module.split() |> List.last()
end
