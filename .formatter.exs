# Used by `mix format`.
# Once AshArcadic.DataLayer defines its `arcade do ... end` DSL, list its section
# entries here (and in `export:`) so `mix format` leaves them unparenthesized and
# shares them with consumers that `import_deps: [:ash_arcadic]`. Equivalent to
# `mix spark.formatter --extensions AshArcadic.DataLayer`.
spark_locals_without_parens = []

[
  import_deps: [:ash],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
