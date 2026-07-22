# Used by `mix format`.
# Lists the `arcade do ... end` (AshArcadic.DataLayer) and `replicant do ... end`
# (AshArcadic.Replicant) DSL section entries so `mix format` leaves them
# unparenthesized and shares them with consumers that `import_deps: [:ash_arcadic]`.
# Regenerate with:
# `mix spark.formatter --extensions AshArcadic.DataLayer,AshArcadic.Replicant`
spark_locals_without_parens = [
  client: 1,
  database: 1,
  destination: 1,
  dimensions: 1,
  direction: 1,
  edge: 1,
  edge: 2,
  label: 1,
  multiple?: 1,
  on_truncate: 1,
  properties: 1,
  sensitive: 1,
  similarity: 1,
  skip: 1,
  source_schema: 1,
  source_table: 1,
  sparse_vector_index: 1,
  sparse_vector_index: 2,
  tenant_attribute: 1,
  tenant_database: 1,
  tokens: 1,
  vector_index: 1,
  vector_index: 2,
  weights: 1
]

[
  import_deps: [:ash],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
