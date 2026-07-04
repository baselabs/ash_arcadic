defmodule AshArcadic do
  @moduledoc """
  Ash Framework integration for [ArcadeDB](https://arcadedb.com).

  AshArcadic is the "`ash_postgres` of ArcadeDB": an `Ash.DataLayer` that lets
  Ash resources be backed by an ArcadeDB graph store, translating Ash actions
  and queries into native OpenCypher and executing them through the
  [`arcadic`](https://github.com/baselabs/arcadic) client (the transport — the
  "`postgrex` of ArcadeDB").

  Responsibility split (verified against the `Ash.DataLayer` contract and the
  sibling `ash_age` data layer — see `docs/CHARTER.md`):

    * **Ash core** owns the `multitenancy do ... end` DSL, policies, and the
      tenant concept, and passes the tenant down.
    * **AshArcadic** (this lib) owns the physical mechanism: `set_tenant/3`,
      `can?({:multitenancy, …})`, sensitive-attribute verifiers, and graph
      traversal — everything that makes an ArcadeDB store *Ashy*.
    * **arcadic** owns transport only and is tenant-blind.

  ## Status

  Scaffold only — see `AshArcadic.DataLayer`. The Stage-0 architecture decision
  (ArcadeDB's physical multitenancy primitive: database-per-tenant vs.
  single-DB attribute-scoping) is open and drives the design; it is the first
  thing the brainstorm settles. See `docs/CHARTER.md`.
  """
end
