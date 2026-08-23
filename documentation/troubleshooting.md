# Troubleshooting

A catalog of the errors and sharp edges a host actually hits, each with its
cause and fix. Deeper per-feature detail lives in [`usage-rules.md`](../usage-rules.md).

## Multitenancy

**`tenant required for :context …` (`:tenant_required`)** — a `:context`-multitenant
operation ran with a nil/blank tenant, so no query executed. This is fail-closed
by design (never a base-database read). Fix: pass `tenant:` on every
read/write/load/stream (`Ash.read!(…, tenant: org)`), or set a default tenant
on the action/domain.

**CDC `:tenant_required` halts the pipeline** — a tenant-scoped mirror got a
`:delete`/PK-changing `:update` whose `old_record` lacks the `tenant_attribute`
column. Cause: the source table uses Postgres' default replica identity (key
columns only). Fix: `ALTER TABLE <table> REPLICA IDENTITY FULL` upstream.

**`:cross_database_transaction`** — a transaction opened on one ArcadeDB
database tried to write another (e.g. two `:context` tenants in one
`Ash.transaction`). Single-database sessions are by construction; restructure
so one transaction touches one tenant's database.

## Sorts, filters, keyset

**`Ash.Error.Query.UnsortableField`** — sorting (or `distinct_sort`, or keyset
paging) by a `:binary` (base64 — not byte-order-preserving), `:decimal`
(lexicographic string order ≠ numeric), or composite-typed (`:map`, `:struct`,
`:union`, `{:array, _}`) attribute. Fix: model money as integer minor units;
sort by another field; see usage-rules "D27".

**`UnsupportedFilter`** — the filter used something ArcadeDB cannot push down:
`like`/`ilike`, attribute-to-attribute comparisons, an aggregate or module
calculation ref, a value comparison on a `sensitive` field (only `is_nil` is
allowed), a non-stored (`skip`-ped) field, or a compound temporal RHS
(`if`/arithmetic on the temporal side). The error is value-free (names operator
+ field only). Fix per usage-rules "Query & filter push-down"; for deterministic
searchable encryption, model the column as a plain `:binary` (not `sensitive`).

**`"not filterable"` on a relationship filter** — filtering a source on a
related field whose destination resource carries an authorizer. Ash's
IN-rewrite reads the destination without per-hop authorization, so AshArcadic
rejects it for every actor. Fix: filter/load the destination directly, or drop
the authorizer on that destination if appropriate.

**`KeyError` inside Ash core (`scope_refs`) on a relationship-path string
function** — an upstream Ash bug (documented); use a flat filter.

**Keyset page 2 fails after a field policy** — the cursor is computed from a
field the actor cannot read (redacted). Sort keyset pages by a field the actor
can read.

## Writes & concurrency

**`StaleRecord` on update/destroy** — the tenant-scoped, filter-scoped match
found zero rows: cross-tenant same-PK, already-deleted, or an
`upsert_condition` that evaluated false (single-row contract). Expected
behavior, not data loss.

**HTTP 503 / `ConcurrentModificationException`** — optimistic-lock contention
on a vertex type's buckets. Autocommit statements already retry (server-side +
client jittered backoff; knob `config :ash_arcadic, :write_conflict_retries`).
Session (`transaction: :batch`) bulk conflicts surface at COMMIT where no
statement retry is safe. Fixes: `Ash.bulk_*` with `transaction: false`
(converges), pre-create hot types with more buckets
(`CREATE VERTEX TYPE X BUCKETS 32`, host-side), and check `result.status`.

**Duplicate rows from concurrent upserts of the same NEW identity** — ArcadeDB
enforces no identity uniqueness by default; two concurrent `MERGE`s can both
create. Fix: a unique index on the identity (host-side DDL) or serialize
writers.

**`upsert returned no row` / `AshArcadic requires a primary key…`** — an
upsert returned nothing (delete raced the write), or update/destroy ran on a
resource with no primary-key attribute to match. The latter is a resource
definition bug.

## Values & encoding

**Write rejected value-free, naming an attribute** — the value is not
JSON-wire-encodable (typically a raw non-UTF8 binary nested inside a `:map` /
`:list` value). Fix: encode app-side (`Base.encode64`) or use a `:binary`-typed
attribute (top-level binaries are handled).

**`:decimal` range filters rejected** — decimals store as exact strings;
range/order comparisons would be lexicographic. Fix: integer minor units for
money that needs range/sort.

**Case-sensitivity surprise** — `contains`/`string_starts_with`/
`string_ends_with` map to ArcadeDB case-SENSITIVE predicates; `:ci_string`
semantics are not preserved. Fix: normalize case app-side.

## Vector search

**Fewer results than expected from a sparse index, silently** — ArcadeDB sparse
indexes do not cover rows written before the index was created. Create sparse
indexes before loading data, or re-touch pre-existing rows.

**`max_vector_candidates` exceeded (fails closed)** — the tenant's candidate
set for `:attribute`-scoped search exceeded the ceiling (default 10 000). Never
truncates by design. Fix: narrow the pre-filter, raise
`config :ash_arcadic, :max_vector_candidates`, or prefer `:context` (physical
DB per tenant) for very large tenants.

**Full-text index creation fails (`SchemaException`, HTTP 500)** — ArcadeDB cannot
build a `FULL_TEXT` index over a property that was auto-created implicitly by
writes (a dynamic property). Declare it first:
`CREATE PROPERTY <Type>.<prop> STRING` (host-side SQL), then
`Arcadic.FullText.create_index/4`. Dense/sparse vector indexes tolerate implicit
properties, but declare yours anyway — explicit schema-before-index is the
reliable order.

## Transactions

**`:transaction_begin_failed` / `:transaction_commit_failed`** — the ArcadeDB
session could not begin (connection/availability) or the commit failed (e.g.
MVCC conflict at commit). A failed commit rolls the session back automatically;
retry the action.

**A spawned task can't see the transaction** — transaction sessions are
owner-process-only by design (Ash keeps actions in-process). Do not hand
transactional work to spawned tasks.

## CDC sink (`AshArcadic.Replicant.*`)

**`:empty_index`** — the sink's `domains` contain no mirror resource, so the
sink halts before opening a transaction (never silently advances the
watermark). Register the mirror resource on a domain listed in the sink's
`domains:`.

**`:sensitive_plaintext`** — an arriving Postgres column maps to a `sensitive`
target attribute and is not in the `replicant` `skip`. Halted value-free. List
the column in `skip`, or model the target as a plain `:binary` if it arrives
already-encrypted (searchable-encryption escape hatch).

**`:checkpoint_read_fault` at pipeline start** — the watermark vertex could not
be read, so the snapshot-vs-resume decision is undecidable; the pipeline halts
(operator retry) rather than guessing. Check ArcadeDB availability and the
checkpoint resource's `client:` (must target the same database as the mirrors).

**`:truncate_halt`** — upstream `TRUNCATE` on an `on_truncate: :halt` mirror.
Either accept the halt (fail-closed default) or declare `on_truncate :mirror`.

**`AshArcadic.Replicant.Apply … is undefined` after adding `replicant` later**
— the optional-dep compile gate needs a one-time rebuild:
`mix deps.get && mix deps.clean ash_arcadic --build && mix compile`
(see [Upgrading](upgrading.md)).

## Timeouts & hangs

**An action hangs against a stalled ArcadeDB** — arcadic commands have no
timeout by default. Set `timeout: <ms>` (and transport pool options) in your
client module's `Arcadic.connect/3` — the data layer uses your conn as-is:

```elixir
def conn do
  Arcadic.connect(url, db, auth: {"root", pass}, timeout: 15_000)
end
```

**`Ash.transaction`'s `timeout` opt is not enforced by this data layer.** The
transaction marker and the ArcadeDB session live in the caller's process
dictionary (owner-process-only by design), so a task-wrapped body with a kill
timer would lose the session; and every wire call inside the transaction is
already bounded by the conn's per-call `timeout` above. For a wall-clock bound
around a whole action, wrap the call at your own boundary (`Task.async` +
`Task.yield` with a shutdown).
