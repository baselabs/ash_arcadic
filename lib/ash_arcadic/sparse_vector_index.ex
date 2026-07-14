defmodule AshArcadic.SparseVectorIndex do
  @moduledoc """
  Sparse (learned-sparse / BM25-style) vector-index configuration declared in an
  `arcade do … end` block. The `%AshArcadic.SparseVectorIndex{}` struct is the target of the
  `sparse_vector_index` DSL entity; it is **declaration only** — metadata the read path reads at
  query time (the `Type[tokens,weights]` reference), plus compile-time validation
  (`ValidateSparseVectorIndex`). AshArcadic does NOT create the index — the host app runs
  `Arcadic.Vector.create_sparse_index/5` (there is no migration/DDL machinery here).

  Unlike a dense `vector_index` — whose `name` IS the vector attribute — a sparse index needs a
  logical `name` plus a `(tokens, weights)` attribute PAIR: `tokens` (an integer-array attribute of
  token ids) and `weights` (a float-array attribute of the matching weights). No `dimensions`/
  `modifier`: those are host-side index-creation metadata with no query-time consumer (sparse token/
  weight vectors are variable-length — there is no query-vector length to validate).
  """

  defstruct [
    :name,
    :tokens,
    :weights,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          tokens: atom(),
          weights: atom()
        }
end
