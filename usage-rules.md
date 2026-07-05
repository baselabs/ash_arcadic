# ash_arcadic usage rules

_An Ash DataLayer for ArcadeDB (native OpenCypher over HTTP)._

> Slice 1 (Plans 1–4) landed: the `arcade do ... end` DSL section, query
> compilation, CRUD, the multitenancy write path, transactions, and bounded
> traversal are live. The binding facts:

## What ash_arcadic owns (and what it does not)

- **Owns:** the physical mechanism that makes an ArcadeDB store Ashy —
  `set_tenant/3` / `can?({:multitenancy, …})`, sensitive-attribute verifiers,
  Cypher generation, and traversal as an Ash manual relationship.
- **Does not own:** transport (that is `arcadic`, tenant-blind) or the
  `multitenancy` DSL and tenant concept (that is Ash core, which passes the
  tenant down).

## Non-negotiable rules (inherited design)

- **Parameters only.** Every value reaches ArcadeDB as a bound `$param` via
  `arcadic`; identifiers (labels, db names) are allowlist-validated. No string
  interpolation into Cypher.
- **Wire-encodable values only.** Written property values must be JSON-encodable.
  Scalars, dates/times, decimals, and top-level binaries (base64'd) are handled;
  a **raw non-UTF8 binary nested inside a `:map`/`:list`** value is not — encode it
  app-side (`Base.encode64`) or use a `:binary`-typed attribute. The write path
  **pre-checks and fails closed** with a value-free error naming the attribute,
  rather than letting the JSON encoder raise with the bytes in the message.
- **Sensitive means encrypted-binary.** A `sensitive` attribute must be
  app-side-encrypted binary (e.g. AshCloak) or `skip`ped; the data layer verifies
  the type shape, not the ciphertext. The multitenancy discriminator is never
  `sensitive` (it is a plaintext selector).
- **`MERGE` is used** for idempotent upsert (ArcadeDB-verified) — unlike the
  `ash_age` sibling. Do not import AGE's "never MERGE" rule.

## Query & filter push-down (Plan 2)

- **Supported filter operators:** `==` / `!=` / `>` / `<` / `>=` / `<=` / `in` /
  `is_nil`, boolean `and`/`or`/`not`, and the string-match functions `contains`,
  `string_starts_with`, `string_ends_with` (→ ArcadeDB `CONTAINS` / `STARTS WITH` /
  `ENDS WITH`). Anything else (`like`/`ilike`, attribute-to-attribute comparisons,
  aggregates/exists) returns a value-free `UnsupportedFilter` — filters fail closed,
  never silently drop scoping.
- **String-match is case-SENSITIVE.** ArcadeDB `CONTAINS`/`STARTS WITH`/`ENDS WITH`
  do not honor a `:ci_string` attribute's case-insensitive semantics.
- **`:decimal` is money-safe but range/sort-restricted (D27).** Decimals are stored
  as their exact string form, so equality / `in` / `is_nil` work, but `gt/lt/gte/lte`
  are **rejected** (`UnsupportedFilter`) and `:decimal` is **unsortable** — ArcadeDB
  compares the string form lexicographically, which would be silently wrong for a
  numeric range/order. **Model money as integer minor units** when you need range
  filtering or sorting. (`:binary` attributes are likewise unrangeable/unsortable —
  base64 is not byte-order-preserving.)

## Multitenancy (Plan 2)

- **`:context` = database-per-tenant** (strongest isolation): `set_tenant/3`
  re-targets a physically distinct ArcadeDB database. A nil/blank tenant fails
  closed (no query runs) — never a silent base-database read/write. The per-resource
  `database` DSL option is **ignored for `:context`** (the tenant resolves the
  database; a static value can never pre-seed and defeat the fail-closed read). No
  cross-tenant traversal. **`:context` database names are operator-visible** on the
  server; use a `tenant_database` MFA to hash a classified tenant space if the
  tenant identity is sensitive.
- **`:attribute` = discriminator on a shared graph:** Ash core injects the
  `<discriminator> == <tenant>` filter (read) and force-sets it (write); AshArcadic
  compiles the injected filter to a scoped `WHERE`. A cross-tenant update/destroy
  matches zero rows and fails closed as `StaleRecord` (the scoped query runs and
  matches nothing — never a silent unscoped mutation). One graph, cross-tenant
  traversal possible.
- **Upsert via native `MERGE`:** an action with `upsert? true` maps to
  `MERGE (n:Label {<identity>}) ON CREATE SET … ON MATCH SET …` — idempotent on the
  primary key (or a composite identity). For an **`:attribute`-multitenant**
  resource the tenant discriminator is **added to the MERGE identity**, so a
  same-PK upsert from another tenant matches nothing and creates its own row (MERGE
  matches the whole node pattern and cannot compose a `WHERE`, so the discriminator
  must ride the identity — otherwise it would hijack the other tenant's row).
  **Bulk upsert is not supported** — a bulk `upsert? true` action **fails closed**
  with an error (it never silently `CREATE`s duplicates); use a single-row upsert.

## Transactions (Plan 3)

- **Transactions are single-database.** A transaction opens one ArcadeDB session,
  bound to one database. A **cross-database write inside a transaction fails closed**
  (`:cross_database_transaction`) — an atomic write spanning two tenants' databases
  (`:context` multitenancy) is impossible by construction, never a silent split-brain
  write on a fresh connection. A cross-database *read* inside a transaction is allowed
  and runs on its own connection (a read is not an atomicity hazard). The guard blocks
  the **offending write** (returns the `:cross_database_transaction` error); rolling back
  the transaction's **prior** in-session writes then depends on that error being
  propagated. Ash does this for you — a data-layer error aborts the action and triggers
  rollback — so a normal Ash action stays atomic. If you drive `transaction/4` directly
  and *swallow* the error, the prior writes commit; propagate it (or call `rollback/2`).
- **Read-own-writes on the same database.** The session opens lazily on the **first
  write**; a read issued after that write (on the transaction's database) reuses the
  session and therefore **sees the transaction's own uncommitted writes**. A read
  *before* any write runs on a plain connection (no session yet).
- **Owner-process only.** The transaction session lives in the calling process; Ash
  disables async inside a transaction, so every action runs in that process. Do not
  hand a transaction's work to a spawned task or a separate process — it will not see
  the session.
- **The duplicate-PK residual is a data-model problem, not a transaction one.** Inside
  a transaction a duplicate-primary-key update (two rows sharing a PK) matches >1 row,
  fails as `UpdateFailed`, and the mutation rolls back atomically (nothing is left
  half-written). To prevent the duplicate rows in the first place, add a **unique
  index on the primary key** in your host-app `arcadic` migration — that removes the
  residual entirely rather than relying on the transaction to clean it up.

## Traversal (Plan 4)

- **Bounded graph reach as a manual relationship.** Declare a `has_many` whose
  `manual` is `AshArcadic.ManualRelationships.Traverse` to traverse edges:

      has_many :descendants, MyApp.Node do
        manual {AshArcadic.ManualRelationships.Traverse,
                edge_label: :PARENT_OF, direction: :outgoing, min_depth: 1, max_depth: 3}
      end

  `edge_label` is required and identifier-validated; `direction` is
  `:outgoing | :incoming | :both`; `max_depth` is a required integer ≥ 1 (unbounded
  `*` is forbidden); `min_depth` defaults to 1. Loading the relationship returns the
  reachable destination records, deduped per source.
- **Slice 1 does not write edges.** Traversal reads edges written out-of-band
  (host-app ingestion / raw `arcadic` Cypher). Edge *writes* (an `edge` DSL entity)
  are a later slice.
- **Traversal is fail-closed multitenant.** A blank tenant runs no query. `:context`
  traversal is physically scoped to the tenant's database (no cross-tenant reach).
  `:attribute` traversal scopes **every node on the path** via the native predicate
  `ALL(x IN nodes(p) WHERE x.<attr> = $tenant)` — an in-tenant node reachable only
  through an out-of-tenant intermediate is **excluded**, not just the endpoints.
  Traversing between two `:attribute` resources with **different** discriminators
  fails closed (`:mixed_attribute`) — one tenant value cannot honor two dimensions.
- **Traversal applies tenant scoping ONLY — not the related query's filters or Ash
  policies.** Like the `ash_age` manual-relationship pattern it ports, traversal
  returns all edge-reachable, tenant-scoped destinations and does **not** apply the
  loaded relationship's `filter`/`sort`/`limit`, a caller-supplied query filter, or
  the destination resource's **Ash read policies** (those ride Ash's `context.query`,
  which the manual relationship does not consume). Multitenant isolation is enforced
  (via the path predicate above), but authorization/field policies are **not** —
  enforce non-tenant authorization via the graph structure, the tenant boundary, or a
  post-load filter on the returned records. Policy-/filter-aware traversal is a
  deliberate future-slice item, not a Slice-1 capability.

See `docs/CHARTER.md` for architecture and the open multitenancy decision; `AGENTS.md`
for the full working rules.
