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

  @spec vector_indexes(Ash.Resource.t()) :: [AshArcadic.VectorIndex.t()]
  def vector_indexes(resource) do
    resource
    |> Extension.get_entities([:arcade])
    |> Enum.filter(&match?(%AshArcadic.VectorIndex{}, &1))
  end

  @spec vector_index(Ash.Resource.t(), atom()) :: AshArcadic.VectorIndex.t() | nil
  def vector_index(resource, name) when is_atom(name) do
    resource |> vector_indexes() |> Enum.find(&(&1.name == name))
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
  Whether `field` is a STORED ArcadeDB property — a declared attribute NOT in `skip`. It is the
  only kind of field a `n.<field>` Cypher reference (sort or a value-reading aggregate) can name.
  False for a calculation/aggregate NAME (not a declared attribute at all) and for a
  declared-but-skipped attribute (never persisted as a property). Drives the fail-closed guards
  on the record-read sort path (`sort/3`), the aggregate `:first` sort path, and the aggregate
  value-reading field: a non-stored field fails LOUD value-free rather than emitting `n.<field>`
  against a non-existent property, which ArcadeDB treats as null (a silently arbitrary sort /
  a silent default aggregate value).
  """
  @spec stored_field?(Ash.Resource.t(), atom()) :: boolean()
  def stored_field?(resource, field) when is_atom(field),
    do: Map.has_key?(attribute_map(resource), field)

  @doc """
  Whether `field` may be translated into a Cypher VALUE expression — a stored property
  (`stored_field?/2`) that is not `sensitive` (app-side-encrypted binary; a plaintext op over
  ciphertext is meaningless). The classification predicate for Cypher value-translation.
  `Query.Expression`'s Ref guard uses it; `Filter.filterable_field?/2` is unified onto it in the
  filter-wiring task, eliminating the S6 divergence class
  (`project_filter_guard_presence_predicate_coverage`). Presence (`is_nil`) uses `stored_field?/2`
  alone — a sensitive field IS presence-checkable (the documented oracle, D9).
  """
  @spec value_translatable_field?(Ash.Resource.t(), atom()) :: boolean()
  def value_translatable_field?(resource, field) when is_atom(field),
    do: stored_field?(resource, field) and field not in sensitive(resource)

  defp default_label(resource), do: resource |> Module.split() |> List.last()
end
