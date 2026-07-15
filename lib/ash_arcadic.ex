defmodule AshArcadic do
  @moduledoc """
  Ash Framework integration for [ArcadeDB](https://arcadedb.com).

  AshArcadic is the "`ash_postgres` of ArcadeDB": an `Ash.DataLayer` that lets
  Ash resources be backed by an ArcadeDB graph store, translating Ash actions
  and queries into native OpenCypher and executing them through the
  [`arcadic`](https://github.com/baselabs/arcadic) client (the transport — the
  "`postgrex` of ArcadeDB").

  Responsibility split (verified against the `Ash.DataLayer` contract and the
  sibling `ash_age` data layer):

    * **Ash core** owns the `multitenancy do ... end` DSL, policies, and the
      tenant concept, and passes the tenant down.
    * **AshArcadic** (this lib) owns the physical mechanism: tenancy scoping
      (`:attribute` discriminator or `:context` database-per-tenant, both
      fail-closed), sensitive-attribute classification, graph traversal, and
      query compilation — everything that makes an ArcadeDB store *Ashy*.
    * **arcadic** owns transport only and is tenant-blind.

  ## Where to start

    * `AshArcadic.DataLayer` — the data layer and its `arcade do … end` resource
      section (client, label, sensitive/skip classification, vector indexes,
      edges).
    * `AshArcadic.Client` — the one-callback behaviour that supplies the
      `Arcadic.Conn` (the `repo` analog).
    * `AshArcadic.ManualRelationships.Traverse` — graph traversal as a manual
      relationship (depth ranges, per-hop tenant scoping + authorization).
    * `usage-rules.md` — the per-feature fine print (supported operators,
      pagination, vector search, bulk-write concurrency, limitations).

  Supported surface (0.1.0): CRUD + `MERGE` upserts + atomics, bulk writes
  (incl. query-scoped push-down and MVCC-retry-converging concurrent bulk),
  filter/sort/distinct/combinations push-down, offset + keyset pagination with
  `Ash.stream!`, temporal comparisons, query + traversal aggregates, expression
  calculations, standard relationships + edge writes, dense/sparse/hybrid vector
  search, transactions, `:async_engine` concurrent loads, telemetry — all
  fail-closed multitenant with value-free redacted errors.
  """
end
