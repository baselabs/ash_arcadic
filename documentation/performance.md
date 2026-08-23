# Performance & tuning

Every server-behavior claim on this page was probed live on the pinned ArcadeDB
image this library CI-runs against (**26.8.1**, digest
`sha256:49036720…`) before documenting. `EXPLAIN` and the SQL commands below run
host-side (your client conn or the ArcadeDB console) — the data layer treats
schema and indexes as YOUR surface (the `arcade` DSL declares them; the host
creates them, the same split ash_postgres uses for migrations).

## Buckets: pre-create hot types

ArcadeDB partitions each type across **buckets** (append-only storage files). A
type created with no bucket clause gets a **single bucket** (probed: six
sequential inserts all landed in cluster `#1`), so every write to that type
serializes through one file. Concurrent batch writes to one type contend on its
buckets under MVCC — the failure class is `ConcurrentModificationException`
(HTTP 503, "Please retry").

- **Create hot types with buckets at least matching your write concurrency**:
  `CREATE VERTEX TYPE HotEvent BUCKETS 32` (probed: 12 concurrent batch writers
  spread across buckets `#4/#7/#10/#13/#16/#19…`). **The hard cap is 32** —
  `BUCKETS 64` is rejected: *"Cannot create 64 buckets: maximum is 32"*
  (`IllegalArgumentException`).
- The bucket count is set **at type creation**. Widening an existing type has
  no `ALTER` clause on 26.8.1 (probed: `ALTER CLASS … BUCKETS`/`ADD BUCKET`
  both reject; a bare `CREATE BUCKET` creates an orphan, unattached). Plan
  bucket counts before the first load.
- Buckets reduce contention pressure; they are not a correctness mechanism.
  ash_arcadic's write path already converges MVCC conflicts (the server-side
  `retries: 10` body param plus bounded client-side jittered backoff, wired at
  every write — `usage-rules.md` § Query-scoped bulk writes): a probe of 12
  concurrent 60-row `bulk_create`s (6 runs each) completed 100% on both a
  default-bucket and a `BUCKETS 32` type. Pre-create buckets when you see
  partial failures under concurrency or want to keep retry pressure low.

## Property indexes: declare the property, then index it

A filter on an unindexed property is a type scan. Index the properties your
reads filter on — edge/traversal FK properties above all.

```sql
CREATE PROPERTY Person.email STRING                 -- declare first
CREATE INDEX ON Person(email) NOTUNIQUE             -- then index
```

- Probed on 26.8.1: the `CREATE INDEX ON Type(prop) <TYPE>` types are
  **`UNIQUE` | `NOTUNIQUE` | `FULL_TEXT`** (a type is REQUIRED; `LSM`,
  `SBTREE`, `HNSW` are rejected as SQL index types — dense/sparse vector
  indexes ride `Arcadic.Vector.create_dense_index!/create_sparse_index!`,
  declared in the `arcade` block and created host-side).
- Probed via `EXPLAIN`: an equality filter on an indexed property plans as
  `FETCH FROM INDEX Person[email]` — the index is used, no scan.
- **Index before load, especially for `FULL_TEXT`**: a full-text index over a
  property that was auto-created implicitly by writes fails outright —
  `SchemaException` *"Cannot create the index … because the property does not
  exist"* (probed); declare the property explicitly first, then the index.
- **Sparse vector indexes do not backfill**: rows written before the index was
  created are not covered (silent misses — see
  [Troubleshooting](troubleshooting.md) § Vector search). Create sparse
  indexes before loading data, or re-touch pre-existing rows.
- A `UNIQUE` index is also the hard guarantee for concurrent `MERGE` upserts
  of the same NEW identity (without one, two writers can both create —
  `usage-rules.md` § Non-negotiable rules).
- `Ash.stream!` keyset pages full-scan and sort each page over an unindexed
  sort field (there is no sort-index DSL); a host-side index on the sorted
  property is the fix.

## `max_vector_candidates`: sizing the tenant candidate ceiling

An `:attribute`-scoped (single-database) vector search builds its candidate RID
set from a tenant-filtered read, then runs the kNN over exactly that set — the
ceiling is what keeps the second phase bounded.

- Default **10 000**, raised via `config :ash_arcadic, :max_vector_candidates,
  N` (validated `pos_integer`; anything else falls back to the default — under
  Erlang term ordering a raw comparison against a string is always false,
  which would silently disable the ceiling).
- The guard **fails closed and never truncates**: a scoped set over the
  ceiling surfaces as a value-free `QueryFailed` ("scoped candidate set
  exceeds max_vector_candidates; narrow the read") — truncation could silently
  drop the true nearest neighbour. A `[:ash_arcadic, :vector,
  :candidate_count]` telemetry event carries the actual count, so you can see
  how close production runs are before raising the ceiling.
- **Fix the shape before raising the number**: narrow the pre-filter, or move
  very large tenants to `:context` multitenancy (a physical database per
  tenant skips the candidate-set path entirely — direct kNN with no ceiling).
- The ceiling only applies to the `:attribute` strategy (filtered candidate
  sets). Unfiltered `:context`/global searches go straight to kNN.
