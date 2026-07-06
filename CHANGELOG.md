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
- **Traversal upgrade (Slice 2, Plan 2 — spec §7).** Makes the bounded traversal
  (`AshArcadic.ManualRelationships.Traverse`) edge- and authorization-correct.
  (1) **`relationships(p)` edge-property scoping**, DEFAULT-ON for `:attribute`: the
  path predicate now scopes every **edge** as well as every node
  (`ALL(r IN relationships(p) WHERE r.<attr> = $tenant)`, probe E4) — an out-of-band
  edge lacking the tenant stamp is *excluded* (fail-closed, not a cross-tenant
  reachability leak); the new manual opt **`scope_edges: false`** opts out for
  node-structure-only graphs. (2) **Option-B two-phase authorized read** (resolves the
  Plan-4 CV1 carry): the traversal becomes a tenant-scoped reachability primitive that
  returns destination PKs, then delegates all authorization/query concerns to a
  standard authorized `Ash.read` over those PKs — applying **row policy** (→ Cypher
  `WHERE`), **field policy** (redaction), and the relationship/caller **filter + sort +
  limit** by Ash's own read pipeline. A policy-denied destination is now dropped **even
  on the PK-only load**; the tenant boundary is enforced twice over (path predicate +
  the read's `:attribute` filter / `:context` database), both fail-closed. Destinations
  must have a single-attribute primary key (composite → fail-closed value-free). Adds
  `{:simple_sat, "~> 0.1"}` (the SAT solver `Ash.Policy.Authorizer` requires). **Slice 2
  is now feature-complete** (edge writes + traversal upgrade); closeout review pending.
- **Query aggregates (Slice 3, Plan 1).** The `run_aggregate_query/3` data-layer callback
  powers `Ash.count/sum/avg/min/max/first/list/exists?/aggregate` (incl. `uniq?`) and
  offset-pagination `count: true` over AshArcadic resources, **tenant-scoped fail-closed**
  (`:context` blank tenant → error, never a base-database read; `:attribute` rides Ash-core's
  injected discriminator filter). A new pure `AshArcadic.Aggregate` builds ONE parameterized
  Cypher statement per aggregate — each honoring its **own per-aggregate filter** (ANDed onto
  the tenant scope; an unpushable per-agg filter fails closed `UnsupportedFilter`, never a
  silent unscoped aggregate) — reusing the Slice-1 `Query`/`Filter`/`Cast`/`read_conn`
  primitives (no forked enforcement path). `{:query_aggregate, kind}` is advertised for
  count/sum/avg/min/max/first/list/exists (custom rejected); `{:aggregate,_}` /
  `{:aggregate_relationship,_}` / `{:lateral_join,_}` stay unsupported (ArcadeDB has no window
  functions and a manual traversal can't be pushed into an aggregate — use a standalone
  `Ash.aggregate`). **Empty (and all-null-field) sets decode to Ash's per-kind default, not
  ArcadeDB's:** `sum`/`avg`/`min`/`max`/`first` over a set with no non-null field values → `nil`
  (a `count(n.<field>)` non-null-count companion disambiguates ArcadeDB's `sum → 0`, matching
  Ash/SQL null-skipping semantics); `count → 0`; `list → []`; a caller `default_value` is
  honored. **Storage-class guard (fail-closed value-free):** `sum`/`avg` require numeric
  (`:integer`/`:float`) storage; `min`/`max`/`first` require order-preserving storage (reject
  `:binary` + `:decimal`, per D27); `list` rejects `:binary` (an encrypted/`sensitive`
  attribute would otherwise return ciphertext) — a rejected aggregate names only the field +
  kind, never a value. Adds an `:aggregate` telemetry span (`kinds` / `aggregate_count`).
- **Per-source traversal limits (Slice 3, Plan 2 — spec §7).** Two static opts on the
  `AshArcadic.ManualRelationships.Traverse` manual relationship — **`per_source_limit`**
  (a positive integer; default `nil` = unbounded) and **`per_source_offset`** (a non-negative
  integer; default `0`) — cap each source's reachable destinations at a per-source top-N,
  sliced `offset..+limit` by the relationship's own **sort**. The slice is applied
  **POST-authorization** (over the already row-policy-authorized, already-sorted Read-B
  destinations in `regroup`, never a DB-side `CALL{}` limit that would slice reachability
  before authz) — a policy-denied destination **never consumes a slot** (integration-proven on
  a fan-out star: denying a sibling yields the next-ranked survivor, not a short result). Ash
  rejects *dynamic* `limit`/`offset` on manual relationships, so these are static
  resource-declared opts; `per_source_limit` is **rejected value-free on a `:one` relationship**
  (a single destination cannot be a top-N). **Completes Slice 3.**

### Fixed

- **`/review-autopilot` closeout (Slice 3, Plan 1, 2026-07-06).** Three correctness/leak gaps
  between the spec's intent and the shipped query aggregates:
  - **`include_nil?: true` silently dropped nulls** — a `list`/`first` aggregate with
    `include_nil?: true` ran plain `collect(...)` (which skips nulls). Now fails closed
    value-free (spec §6.5); null-preserving support remains a future capability.
  - **all-null-field aggregates bypassed the Ash default** — the empty-vs-zero companion was
    `count(n)` (counts rows), so an aggregate over a set whose field is null in every row
    returned ArcadeDB's raw value (`sum → 0`, `min → nil`) instead of the Ash default. The
    companion is now `count(n.<field>)` (non-null count), matching Ash/SQL null-skipping.
  - **`:first` sort by a non-atom field could leak** — an expression/calculation sort field
    raised a value-carrying `Protocol.UndefinedError`. Now rejected value-free before any
    identifier coercion (Rule 4).
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
