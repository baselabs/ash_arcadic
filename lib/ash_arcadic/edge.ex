defmodule AshArcadic.Edge do
  @moduledoc """
  Edge configuration for an ArcadeDB relationship declared in an `arcade do … end`
  block. The `%AshArcadic.Edge{}` struct is the target of the `edge` DSL entity;
  `AshArcadic.Changes.{CreateEdge,DestroyEdge}` read it by `name`.

  `multiple?` selects the write primitive: `false` (default) → idempotent `MERGE`
  (one edge per endpoint pair, label and declared identity values); `true` →
  `CREATE` (parallel edges without an identity).
  """

  defstruct [
    :name,
    :label,
    :destination,
    direction: :outgoing,
    properties: [],
    identity: [],
    multiple?: false,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          label: atom(),
          direction: :outgoing | :incoming | :both,
          destination: module(),
          properties: [atom()],
          identity: [atom()],
          multiple?: boolean()
        }
end
