# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Keyset pagination + `Ash.stream!` (Slice 11).** `can?(:keyset)` advertised (with the required
  `data_layer_keyset_by_default?/0 → false` callback): `page: [after:/before: cursor, limit:, count:]`
  and `Ash.stream!` use efficient cursor pagination over any stored comparable sort attribute
  (`:integer`/`:float`/`:boolean`/`:string`/datetime/time incl. microsecond), with the primary key as
  tiebreaker. Cross-tenant isolated on both strategies; `page: [count: true]` tenant-scoped. A
  `:binary`/`:decimal` sort fails closed `UnsortableField`; a non-stored/calc/aggregate sort fails
  closed value-free `UnsupportedFilter`. Perf guarantee is bounded MEMORY (streaming), not bounded
  time — no sort-index DSL, so add a host-side index for deep-pagination speed.
- **`:async_engine` — concurrent reads/loads (Slice 11).** Probe-verified pool-safe: Ash runs
  independent relationship/aggregate loads concurrently on a read (transactional actions stay sync) —
  always safe/deterministic.
- **Concurrent bulk writes converge (Slice 11).** Every autocommit write statement retries an
  optimistic-lock conflict (`ConcurrentModificationException` — bucket contention) at two levels:
  ArcadeDB's server-side statement retry (arcadic `retries:`) + a client-side jittered-backoff retry —
  both idempotency-safe by construction (autocommit is all-or-nothing) and Ash hooks are never
  re-fired. `Ash.bulk_*` with `transaction: false, max_concurrency: N` converges fully even on a
  default-bucket type (deterministic 80/80 × 10 runs; a batch is one `UNWIND` statement, so
  `transaction: false` costs no atomicity). The default `transaction: :batch` (session per batch)
  conflicts at COMMIT where no statement retry is safe — pre-create hot types with buckets ≥
  concurrency and check `.status` there. Knob: `config :ash_arcadic, :write_conflict_retries, N`.

### Fixed

- **Temporal range/eq/`in` comparisons no longer silently return `[]` (Slice 11).** ArcadeDB
  auto-coerces stored ISO8601 datetime/time strings to native temporal types; AshArcadic now wraps the
  bound comparison param in the matching Cypher constructor (`datetime()` for `:utc_datetime`/
  `:naive_datetime`/usec, `localtime()` for `:time`/usec) so `:datetime`/`:time` filters and keyset
  cursors compare correctly. `:date` is unaffected (kept a string). A COMPOUND temporal comparison
  (temporal attr vs a value-expression) now fails closed value-free (`UnsupportedFilter`) instead of
  silently returning `[]`.
- **Composite-typed sorts fail closed (Slice 11).** A keyset/`ORDER BY` over a `:map`/`:struct`/
  `:union`/`{:array, _}` attribute (no total order) is now rejected `UnsortableField` instead of
  silently mis-paging/mis-ordering.

### Security

- **Read-path value-free encode-gate (Slice 11).** A non-encodable value in a read filter literal (a
  raw non-UTF8 binary nested in a `:map`/`:list`) now fails closed value-free (`%QueryFailed{}` naming
  the failure class, never the bytes) at every read wire site (flat, aggregate/count, combination,
  traversal, vector-candidate) — closing the last surface of the `Jason.EncodeError` byte-leak class
  (AGENTS.md Rule 4) on the read path.

- **Vector search — dense kNN (Slice 10, Plan 1).** ArcadeDB dense vector similarity search is
  first-class: declare `vector_index :embedding, dimensions:, similarity:` in the `arcade` block
  (metadata + compile validation — the host creates the index via `Arcadic.Vector.create_dense_index`;
  no migration machinery), attach `AshArcadic.Preparations.VectorSearch` to a read action whose
  `:query_vector`/`:k` arguments drive the search, and read records ranked closest-first with the
  distance on `record.__metadata__[:vector_distance]`. Executes through the ArcadeDB SQL
  `vector.neighbors` path (separate from the Cypher engine). **Fail-closed multitenant:** `:context`
  runs the kNN in the tenant DB; `:attribute` SELF-INJECTS the tenant predicate (never trusting Ash's
  filter — a `:bypass` action cannot leak) and scopes via the native candidate-set `filter:`; a
  no-tenant search fails closed. Cross-tenant search is a deliberate two-part opt-in (Ash action
  `multitenancy :allow_global`/`:bypass` AND preparation `allow_global?: true`). Candidate cardinality
  is bounded by `max_vector_candidates` (default 10 000, config-overridable) — reject, never truncate.
  Params-only, value-free; `can?(:vector_search)` / `can?({:vector_search, :dense})` advertised; a
  `vector_search?` read-span telemetry tag.
- **Vector search — sparse + hybrid fusion (Slice 10, Plan 2).** Extends the vector slice with
  **sparse** (learned-sparse / BM25-style) kNN and **hybrid fusion**. Declare a `sparse_vector_index
  :name, tokens:, weights:` over a `(tokens, weights)` attribute pair (both stored, non-`sensitive`,
  array-typed — compile-verified); host-creates via `Arcadic.Vector.create_sparse_index`. Attach
  `AshArcadic.Preparations.VectorSearch` with `kind: :sparse` (arguments `:query_tokens`/
  `:query_weights`/`:k`) or `kind: :hybrid` with an `arms:` list of `{:dense, index}` |
  `{:sparse, index}` | `{:fulltext, property}` (≥2 arms; `fusion` `:rrf`/`:dbsf`/`:linear`). Sparse and
  hybrid results rank by `score` on `record.__metadata__[:vector_score]` (dense keeps `distance`).
  The full-text fuse arm ships now (host-created full-text index; its DSL declaration surface is a
  later slice). **Tenant scoping is identical to dense** — the self-injecting candidate-set scopes the
  sparse arm AND every hybrid arm including full-text (mutation-proven live: a `:bypass` sparse or
  hybrid-full-text action is still scoped by self-injection alone). A crafted/malformed stash fails
  closed value-free per kind. `can?({:vector_search, :sparse})` / `{:vector_search, :hybrid}`
  advertised; value-free `vector_kind` telemetry tag. **Sparse retro-index caveat (documented):** a
  sparse index does not cover rows created before it — create it before loading.
- **Query-scoped bulk writes + atomics (Slice 9, Plan 1).** `update_query`/`destroy_query`
  (`can?(:update_query)` / `can?(:destroy_query)` / `can?(:expr_error)`): a query-scoped bulk update or
  destroy compiles to ONE parameterized Cypher statement — the tenant predicate, caller filter, and
  changeset filter all ANDed into the WHERE — instead of Ash's per-row `:stream` fallback. An empty match
  is a no-op (`{:ok, []}`), never `StaleRecord` (bulk semantics differ from the single-row path). Bulk
  destroy with `return_records?: true` captures each row's properties BEFORE the delete
  (`… WITH n, properties(n) AS p DETACH DELETE n RETURN p`). Atomic expression updates
  (`change atomic_update(:field, expr(field + 1))`) push into Cypher `SET` via a new pure
  `AshArcadic.Query.Write` builder over `AshArcadic.Query.Expression`
  (`can?({:atomic, :update|:create|:upsert})`) — the RHS hydrated then translated, every literal bound;
  atomic `create_atomics` fold into EVERY create surface (single-row `create`, bulk `create`, and the
  upsert `ON CREATE SET`) and `atomics` into the upsert `ON MATCH SET`. A write to the multitenancy
  discriminator (atomic OR static), a `sensitive`/non-stored atomic TARGET (never plaintext into an
  encrypted-binary column), an empty SET, and a `sensitive`/non-stored/`:binary`/`:decimal`/relationship/
  aggregate atomic RHS all fail closed value-free.
  A `limit`/`offset`/`combination_of` on a query-scoped bulk write fails closed (a single `MATCH … SET`/
  `DELETE` cannot honor per-row paging; use `strategy: :stream`), as does a conditional after-batch hook on
  the action. Multitenancy stays fail-closed on every path (`:context` blank tenant → no statement;
  `:attribute` scoped by the WHERE predicate) — a fabricated cross-tenant attacker cannot cross tenants
  (mutation-proven). Write-path params (static + atomic-RHS literals) are JSON-encode-gated before the wire
  (a poisoned value fails closed value-free, never a byte-leaking crash). Read/write-span telemetry gains a
  value-free `matched` tag and `:update_query`/`:destroy_query` spans. Also advertises
  `can?({:filter_expr, <literal>})` so an all-literal filter/atomic that Ash constant-folds
  (`expr(100 + 1)` → `101`) is accepted (bound as a param).
- **Heterogeneous bulk update + multi-row bulk upsert (Slice 9, Plan 2).** `update_many`
  (`can?(:update_many)`): a heterogeneous bulk update — each record its own changes, via `Ash.update_many/4`
  with `strategy: :atomic` — compiles to one `UNWIND … MATCH … SET n += r.set[, <shared atomics>]` statement
  keyed by primary key (records absent from the graph are simply absent from the result). The group's shared
  `changeset.filter` (optimistic lock / atomic validation / policy) AND-composes onto the WHERE, fail-closed
  on an untranslatable filter (symmetric with the single-row `update`/`destroy` path). update_many scopes by
  the ToTenant-normalized tenant (matching the single-row path) and fails closed if one primary key matches
  more than one row (ArcadeDB enforces no PK uniqueness — sibling parity with the single-row cardinality
  guard). Multi-row bulk upsert
  (lifting the prior "MERGE is single-row" rejection): `UNWIND … MERGE … ON CREATE … ON MATCH …` upserts many
  rows in one statement — the merge key including the `:attribute` tenant discriminator so a cross-tenant
  primary-key collision creates a new tenant-local row instead of hijacking another tenant's (fail-closed,
  P4/D4-verified, mutation-proven). Atomic changes fold on BOTH upsert branches (`create_atomics` → ON CREATE,
  `atomics` → ON MATCH); the discriminator is never in the ON MATCH set (D3). `:bulk_create_with_partial_success`
  is **false** (D9 — ArcadeDB enforces a UNIQUE index built via SQL-DDL, but an `UNWIND` batch aborts
  whole-batch with no per-row attribution, so a bulk write is one atomic unit, never partial success).
  Multitenancy stays fail-closed on every path (`:context` blank tenant → no statement; `:attribute` scoped
  by the discriminator); every wire value is JSON-encode-gated value-free. Telemetry gains `:update_many`
  spans and a `bulk_upsert?` tag.
- **Combinations (Slice 8, Plan 2).** `combination_of` support
  (`can?(:combine)` / `can?({:combine, :base|:union|:union_all|:intersect|:except})`):
  native `UNION`/`UNION ALL` Cypher push-down — one `CALL { <branch> UNION[ ALL] <branch> } … RETURN n`
  statement — when every branch is union-family; an in-memory primary-key-keyed set-op fold when any
  `intersect`/`except` is present (ArcadeDB has no `INTERSECT`/`EXCEPT`, live-verified parse error), which
  fetches each branch's full filtered result set into the app before combining. Combinations return whole
  vertices (no field-projection `select`); the fold keys on the primary key. Multitenancy is enforced per
  branch: `:context` requires every branch to resolve to the SAME non-nil tenant database (else fail-closed
  value-free — a blank tenant or branches spanning databases are rejected); `:attribute` scoping rides the
  outer `query.filters` (the tenant predicate Ash injects on the outer combination query), applied by the
  native `CALL`-wrap `WHERE` and pushed into every branch on the in-memory path (so a cross-tenant PK
  collision can never enter the fold). An outer `distinct` over a combination keeps an engine-arbitrary
  representative per group (does not honor `distinct_sort` — the union output has no stable pre-collect
  order). Read-span telemetry gains `combination?` / `combination_types` / `combination_strategy`
  (`:native` | `:in_memory`) tags. A **per-branch `limit`/`offset`** routes the combination to the
  in-memory strategy (so the tenant filter applies to each branch before its limit; a spurious `offset: 0`
  default is a no-op). **Fails closed value-free** on combination shapes this slice does not support:
  per-branch `calculations`, a branch expression-calculation `sort`, a mid-chain `:base`, and — when the
  query runs on the in-memory path (any `intersect`/`except` or per-branch paging) — an
  expression-calculation outer `sort` or a lazy outer filter `:expression` (both are honored on the native
  path). Loading an aggregate or calculation ON a combination read also fails closed value-free (out of
  scope this slice). **Documented
  Ash-core limitation (not data-layer-fixable):** a standalone `Ash.count`/`Ash.sum`/`Ash.aggregate` OVER a
  combination silently drops the combination in Ash core (the aggregate action rebuilds the query without
  `combination_of`) and returns the un-combined base result — aggregate a combination by reading it and
  folding app-side.
- **Distinct (Slice 8, Plan 1).** `distinct`/`distinct_sort` support
  (`can?(:distinct)` / `can?(:distinct_sort)`): native Cypher DISTINCT-ON-subset
  (`WITH n.<f> AS __d0, collect(n)[0] AS n`), representative row chosen by `distinct_sort`
  (falling back to the query's `sort`, Ash's documented contract; with neither, the
  representative is engine-arbitrary and the order stage is elided); outer sort/paging apply
  after the dedup. Aggregates over a distinct query (`Ash.count`, page `count: true`,
  `sum`/`min`/…) fold the deduped representatives, never the raw rows. Fails closed
  value-free on a non-stored, `sensitive`, calculation, relationship-path, or non-atom
  distinct entry, and on any sort direction outside Ash's six qualifiers (`distinct_sort`
  reaches the data layer with no upstream validation; the same direction clamp now also
  guards the direct data-layer `sort/3` ingress); `distinct_sort` additionally rejects
  `:binary`/`:decimal` (unsortable storage), symmetric with the record sort path. Dedup is
  per-tenant under both multitenancy strategies. Read-span telemetry gains a `distinct?` tag.
- **Expression calculations (Slice 7).** Ash expression calculations are first-class:
  they **load** (computed in Elixir over the flat `RETURN n`, so sensitive fields stay
  app-decrypted), and **filter-on-calc**, **sort-on-calc**, and raw-attribute
  **filter-expansion** (`filter(res, a + b > 5)`) push down to Cypher via the new
  `AshArcadic.Query.Expression` translator (WHERE / ORDER BY). Supported: arithmetic
  (`+ - * /`, division forced float to match Ash), concat (`<>`), comparison, boolean,
  `if`/`cond` (→ `CASE`), `is_nil`,
  `string_downcase`/`string_length`/`length`/`string_trim`/`round` (`round/1` only), and
  `contains`/`string_starts_with`/`string_ends_with`; a comparison may carry a compound value
  expression on **either** side (`a + b > 5`, `a > b + 1`). A `sensitive` or non-stored field
  in a calc expression **fails closed value-free on all paths** (the data layer holds only
  ciphertext — use a module calc for a derived sensitive value); a **relationship-path** calc
  (`expr(author.name)`) fails closed value-free on all paths, including load (never routed
  through Ash's `authorize?: false` relationship-load fallback); un-mapped operators/functions
  (date/time, `fragment`, `type`) likewise fail closed value-free. All four Ash sort
  nil-placement qualifiers are honored, and a raising calc eval is caught + redacted value-free.
  Parity boundary: pushed filter/sort matches the loaded value except at non-natural
  declared-type coercions, `round/1` of negative half-integers, and division by zero (use a
  module calc there). Advertises the value-operator
  `can?({:filter_expr, …})` set plus `:expression_calculation` / `:expression_calculation_sort`.
  Module calculations and standalone `Ash.calculate` are unchanged.
- **Filter-ops hardening (Slice 6).** Value-comparison filters on a `sensitive`
  (app-side-encrypted binary) field now fail closed value-free (`%UnsupportedFilter{}`)
  instead of silently returning `[]` — `sensitive` is the "do not filter" contract, with
  `is_nil`/`not is_nil` (presence) allowed as a documented oracle. Value comparisons on
  non-stored (`skip`-ped/computed) fields likewise fail closed value-free (mirroring the
  sort rule); a `%Ref{}` in a non-first string-function argument fails closed value-free.
  A string function over a relationship path (e.g., `contains(rel.field, "x")`) is
  documented as an upstream Ash limitation — Ash 3.29.3's `scope_refs` raises `KeyError`
  before AshArcadic sees the filter; use a flat filter or load-then-filter pending the
  upstream fix. This also closes the Slice-5 sensitive-destination-FK relationship-load
  residual at load time.
- **Standard (attribute-FK) relationships (Slice 5).** `belongs_to` / `has_many` /
  `has_one` / `many_to_many` are first-class for AshArcadic-backed resources — an
  attribute FK stored as a vertex property (NOT a graph edge), loaded/aggregated via
  Ash's core batched-`IN` loader over the existing `run_query` (no new callback). Ships:
  the `{:filter_relationship, standard}` capability (value-keyed off `is_nil(rel.manual)`,
  so `belongs_to`/`m2m` — which carry no `:manual` field — are covered); a
  `ValidateRelationshipFk` compile-verifier (a `sensitive` join attribute fails closed,
  value-free); an `internal?` telemetry tag distinguishing relationship-filter nested reads;
  standard-rel aggregates via the Slice-4 fold (incl. `%Ash.ForbiddenField{}` field-policy
  fail-closed); `exists(rel, …)` and m2m loading (two-`IN` path), tenant-scoped. Manual
  `Traverse` relationships remain fail-closed for filtering (unchanged, regression-pinned).
- **Fail-closed relationship-filter authorization (Slice 5, security).** A source-on-related
  FILTER routes through Ash's separate-read IN-rewrite, which reads the destination
  `authorize?: false` — bypassing the destination's row policy and oracling field-policy-protected
  values (tenant isolation is unaffected). AshArcadic now **rejects** (`"not filterable"`, for
  every actor) filtering across a relationship whose destination carries any authorizer; loading
  and aggregates are unaffected. (Known limitation, **Ash-core, not data-layer-fixable:** the
  `exists(rel, …)` path is not gated by this guard — Ash decomposes a related `exists` into flat
  reads before the data layer sees it, and the one data-layer lever over-rejects Ash's own
  relationship-referencing read policies; the proper fix is an upstream Ash-core hook. See
  `usage-rules.md`. Filtering a source on a **many_to_many** related field is likewise unsupported —
  Ash rejects it (`"cannot access multiple resources…"`) because AshArcadic advertises no join; m2m
  loading and aggregates work.)
- **Filter-on-aggregate fails closed (Slice 5).** `filter(res, <aggregate> > n)` previously
  mis-translated to a non-existent stored property and silently returned `[]`; it now fails
  closed with a value-free `%UnsupportedFilter{}` (aggregate/calculation Refs are computed, not
  stored). A constant-folded boolean predicate (`exists` over an empty match set) now correctly
  translates to a `true`/`false` Cypher literal instead of erroring.

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
  resource-declared opts; `per_source_limit` and `per_source_offset` are **rejected value-free
  on a `:one` relationship** (a single destination cannot be a top-N or be offset into).
  **Completes Slice 3.**
- **Traversal aggregates (Slice 4).** Declared aggregates —
  `count`/`sum`/`avg`/`min`/`max`/`first`/`list`/`exists` — over a manual `Traverse`
  relationship (`aggregates do count :descendant_count, :descendants end`) now compute over a
  node's **reachable subtree**, **POST-authorization in Elixir** (never a DB-side Cypher aggregate,
  which would count policy-denied nodes and double-count multi-path nodes). `add_aggregate/3`
  stashes the aggregate onto `%AshArcadic.Query{}`; `run_query/2` computes it over the just-read
  parents via ONE batched authorized `Ash.load` (Traverse's `UNWIND $ids` — not N+1), threading the
  **real `authorize?`/`actor`/`tenant`** (never `authorize?: false`), then a new thin
  `AshArcadic.TraversalAggregate` folds each source's authorized, node-deduped, tenant-scoped
  destinations (`guard_field` before every fold; fold wrapped value-free). A **policy-denied
  intermediate drops its entire subtree** (integration-proven, mutation-proven: `s→mid(denied)→deep`
  under a non-admin actor counts neither `mid` nor `deep`) and a **cross-tenant node is not counted**.
  `include_nil?` is **honored** for traversal `list`/`first` (a capability gain over the Slice-3 flat
  path, whose Cypher `collect` drops nulls). Empty/all-null-field sets decode to the aggregate's Ash
  default; the storage-class guard (`sum`/`avg` numeric; `min`/`max`/`first` order-preserving; `list`
  rejects `:binary`) is reused value-free — keyed off the **destination** resource's storage types
  (correct for cross-resource traverses, not just self-referential). A **field-policy-redacted**
  destination value (`%Ash.ForbiddenField{}` from Read B) fails the aggregate **closed** value-free —
  an actor cannot aggregate a field they are not permitted to read. `{:aggregate, kind}` /
  `{:aggregate_relationship, _}` now
  advertised; `{:aggregate, :unrelated}` / `{:aggregate, :custom}` stay refused (Ash rejects flat
  inline aggregates upstream). **Standalone `Ash.aggregate` over a relationship path is rejected
  value-free** (`run_aggregate_query/3` fails closed on a non-empty `relationship_path` — load the
  aggregate inline instead; the standalone cross-row collapse semantics are unresolved). Adds
  value-free `traversal_aggregate?`/`aggregate_kinds`/`aggregate_count` telemetry metadata.

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
