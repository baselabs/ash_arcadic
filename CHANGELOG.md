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
