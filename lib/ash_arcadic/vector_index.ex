defmodule AshArcadic.VectorIndex do
  @moduledoc """
  Dense vector-index configuration declared in an `arcade do … end` block. The
  `%AshArcadic.VectorIndex{}` struct is the target of the `vector_index` DSL entity;
  it is **declaration only** — metadata the read path reads at query time (the
  `Type[property]` reference, and `similarity` for `distance`/threshold semantics),
  plus compile-time validation (`ValidateVectorIndex`). AshArcadic does NOT create
  the index — the host app runs `Arcadic.Vector.create_dense_index/5` (there is no
  migration/DDL machinery here, by the same precedent that leaves endpoint-PK indexes
  to the host).

  `name` is the vector attribute (a stored, non-`sensitive`, array-typed property);
  `dimensions` and `similarity` mirror the `Arcadic.Vector` index metadata.
  """

  defstruct [
    :name,
    :dimensions,
    similarity: :cosine,
    __spark_metadata__: nil
  ]

  @type similarity :: :cosine | :dot_product | :euclidean

  @type t :: %__MODULE__{
          name: atom(),
          dimensions: pos_integer(),
          similarity: similarity()
        }
end
