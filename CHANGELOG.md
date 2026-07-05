# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- AshArcadic data-layer foundation (Slice 1, Plan 1) — server-free: the
  `arcade do … end` DSL section + `AshArcadic.DataLayer.Info` introspection; the
  `Ash.DataLayer` behaviour skeleton (`can?/2` advertising `:multitenancy` only,
  `resource_to_query/2` building `%AshArcadic.Query{}`); the `AshArcadic.Client`
  behaviour; the `AshArcadic.Cast` type layer (storage-class serialization + flat
  ArcadeDB-row decode, no `$age64$` tag); the `AshArcadic.Multitenancy` tenant→
  database-name encoder (injective, ≤128 bytes, fail-closed value-free); the
  `EnsureLabelled` transformer (default label ← module name); five compile-time
  verifiers (label format, static database format, sensitive R1–R3, no-PK-in-skip,
  multitenancy discriminator not skipped/binary); the Splode error taxonomy
  (Create/Query/Update/UnsupportedFilter, value-free); and value-free telemetry
  spans with a metadata allowlist. Query/CRUD/transactions/traversal land in
  Plans 2–4.
- Project scaffold: packaging, `import_deps: [:ash]` formatter, `docs/CHARTER.md` +
  `AGENTS.md` context docs, and a documented `AshArcadic.DataLayer` placeholder.
  No data-layer implementation yet — see `docs/CHARTER.md` for the architecture and
  the open Stage-0 decision (physical multitenancy strategy).
- **Query + CRUD + multitenancy write path (Slice 1, Plan 2).** Query compilation:
  `%AshArcadic.Query{}` → parameterized Cypher (filter/sort/limit/offset). Filter
  push-down: eq/not_eq/gt/lt/gte/lte/in/is_nil + `contains`/`string_starts_with`/
  `string_ends_with` (→ `CONTAINS`/`STARTS WITH`/`ENDS WITH`); identifier-validated;
  value-free `UnsupportedFilter` for anything else. CRUD callbacks: `run_query`,
  `create`, `upsert` (native `MERGE`), `update`, `destroy`, `bulk_create`, plus
  `set_tenant`/`set_context`/`filter`/`sort`/`limit`/`offset`. Multitenancy write
  path: `:context` re-targets the database (fail-closed on a blank tenant);
  `:attribute` rides Ash-core's injected discriminator filter (cross-tenant
  update/destroy denied as `StaleRecord`). `Cast` `:time` (ISO8601) and `:decimal`
  (exact string) round-trip. Transactions/traversal land in Plans 3–4.
- **Transactions (Slice 1, Plan 3).** `can?(:transact)` now advertises transaction
  support; `transaction/4` / `in_transaction?/1` / `rollback/2` map Ash's data-layer
  transaction callbacks onto `arcadic`'s low-level session trio. The session is
  **owner-process-only** (a process-dictionary marker + lazily-opened session; Ash
  disables async inside a transaction and never transfers the marker to spawned
  tasks, so no data-layer op runs cross-process) and **lazy write-first** (the first
  write opens the session; a read before any write, and reads/writes on the
  transaction's own database, reuse it — read-own-writes). Single-database by design:
  a **cross-database write inside a transaction fails closed** with a value-free
  `:cross_database_transaction` error (an ArcadeDB session is bound to one database);
  a cross-database or pre-write read runs on its own conn (a read is not an atomicity
  hazard). All transaction error paths are value-free (no tenant-derived database
  name, session id, or Cypher escapes; a begin failure surfaces as a bare
  `:transaction_begin_failed`, a commit failure as `:transaction_commit_failed`).
  Adds a `:transaction` telemetry span (result `:commit` / `:rollback` / `:error`)
  and threads `in_transaction?` into every per-op span's metadata. **Closes the
  Plan-2 CV3/CV4 write-then-error-without-rollback residuals for `transaction? true`
  actions** — a duplicate-PK multi-row update (mutate-then-`UpdateFailed`) now rolls
  the multi-`SET` back atomically instead of leaving the mutation committed.
  A rollback that itself fails or raises during unwind is logged value-free (a static
  line, never the transport error's database-bearing message) and never masks the
  original error. A **failed commit** now rolls the session back before returning
  `:transaction_commit_failed`: a probe against live ArcadeDB confirmed a commit that
  fails with an MVCC `ConcurrentModificationException` leaves the session **open**
  server-side (retryable), so rolling it back frees it immediately instead of leaking it
  until idle expiry. Traversal lands in Plan 4.
- **Bounded graph traversal (Slice 1, Plan 4).** `AshArcadic.ManualRelationships.Traverse`,
  an Ash manual relationship emitting one parameterized `UNWIND $ids AS sid MATCH …
  RETURN` statement (bounded variable-length; `direction` `:outgoing`/`:incoming`/`:both`;
  required `max_depth`, no unbounded `*`). `:context` traversal is physically scoped to the
  tenant database; `:attribute` traversal scopes **every node on the bound path** via
  ArcadeDB's native predicate `ALL(x IN nodes(p) WHERE x.<attr> = $tenant)` — fail-closed on
  a blank tenant or on traversal between resources with different discriminators
  (`:mixed_attribute`). Params-only with identifier validation; value-free errors; a
  `:traverse` telemetry span (`row_count`/`destination_count`/`depth`). `can?(:traverse)`
  advertised. **Completes Slice 1** (the vertex-centric data layer).
- **Edge writes (Slice 2, Plan 1).** AshArcadic-backed resources can now write graph
  edges. An `edge` DSL entity in the `arcade do … end` block (name/label/direction/
  destination/properties + a `multiple?` primitive selector: `false` → idempotent
  `MERGE`, `true` → parallel `CREATE`). Two Ash change modules run as `after_action`
  hooks inside the action's transaction: `AshArcadic.Changes.CreateEdge`
  (`change {CreateEdge, edge:, to:}`) and `AshArcadic.Changes.DestroyEdge`. Both scope
  **both endpoints** (identity + tenant discriminator) in a `WHERE` *before* the
  MERGE/CREATE/DELETE rel-pattern via one shared `EdgeCypher` builder (anti-divergence)
  — a same-PK-in-both-tenants edge write/delete binds only the in-tenant node
  (cross-tenant hijack denied; integration-proven). CreateEdge stamps the `:attribute`
  discriminator onto `:attribute` edges, encode-gates the **full param map** (Rule 4 —
  a raw non-UTF8 binary nested in a `:map`/`:list` fails closed value-free before the
  DB touch), and enforces the **R4 sensitive-property runtime guard** (a `sensitive`
  edge property with no binary-storage-typed argument fails closed, value-free); a
  0-row create → `InvalidRelationship`, a mid-list failure rolls all edges back.
  DestroyEdge count-decodes the `<deleted>` echo — a 0-row delete (already-gone or
  cross-tenant) fails closed as `StaleRecord`. Compile-time guards: `ValidateEdge`
  (edge label + property-key identifiers) and the `ValidateSensitive` **R4** clause (an
  edge-property key naming a sensitive attribute requires a binary-storage-typed
  declared argument). Adds `Info.edges/1` and `:create_edge`/`:destroy_edge` telemetry
  spans (`properties?` added to the value-free allowlist). Plan 2 (traversal upgrade —
  `relationships(p)` edge scoping + the Option-B authorized read) is pending.

### Fixed

- **`/review-autopilot` closeout (Plan 2, 2026-07-05).** Tenant-isolation and
  fail-closed hardening surfaced by the closeout review:
  - **`:attribute` upsert cross-tenant hijack** — the native `MERGE` matched on the
    primary key alone, so a same-PK upsert from another tenant matched and mutated
    the victim's row. The tenant discriminator now rides the MERGE identity
    (tenant-local match; a cross-tenant upsert creates its own row).
  - **`:context` read backstop** — the static `database` DSL option is now ignored
    for `:context` (it no longer pre-seeds `query.database` and defeats the
    fail-closed read on a blank tenant).
  - **JSON-encode leak** — a raw non-UTF8 binary nested in a `:map`/`:list` attribute
    is pre-checked on every write path and fails closed with a value-free error
    (previously the JSON encoder raised with the bytes in the message — a redaction
    breach).
  - **Bulk upsert** — a bulk `upsert? true` action now fails closed instead of
    silently emitting `CREATE` and producing duplicate rows.
  - Added end-to-end coverage for composite-primary-key updates.

### Notes

- `:decimal` range operators (`gt/lt/gte/lte`) are rejected (`UnsupportedFilter`) and
  `:decimal` is unsortable — ArcadeDB compares the exact-string wire form
  lexicographically; model money as integer minor units for range/sort. `:context`
  database names are operator-visible (use `tenant_database` to hash a classified
  tenant space). ArcadeDB `CONTAINS`/`STARTS WITH`/`ENDS WITH` are case-sensitive (a
  `:ci_string` attribute's case-insensitive semantics are not preserved).
