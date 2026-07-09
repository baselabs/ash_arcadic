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
- **Filtering a `sensitive` field is unsupported.** A value comparison (`==`/`!=`/`>`/`<`/`in`/
  `contains`/`string_starts_with`/`string_ends_with`) on a `sensitive` (app-side-encrypted
  binary) field fails closed value-free (`%UnsupportedFilter{}`); `is_nil`/`not is_nil`
  (presence) are allowed.
- **Searchable-encryption escape hatch.** A field needing deterministic/searchable-encryption
  equality is modeled as a PLAIN `:binary` attribute (NOT `sensitive`), where equality on the
  caller-encrypted value works; `sensitive` IS the "do not filter on this field" contract.
- **Presence-oracle residual.** `is_nil`/`not is_nil` on a `sensitive` field is allowed and
  leaves a presence oracle (the has-value cohort is enumerable); treat presence-as-classified
  with a host field policy if required.
- **Filtering a non-stored (`skip`-ped/computed) field is unsupported.** Value comparisons AND
  `is_nil`/`not is_nil` on a non-stored ArcadeDB property fail closed value-free (mirrors the sort
  rule) — the property is never stored, so `is_nil` would match every row. (`is_nil`/`not is_nil` on
  a STORED `sensitive` field stays allowed — the presence oracle above.)
- **A string function over a relationship path is unsupported (upstream Ash bug).** `filter(res,
  contains(rel.field, "x"))` raises a `KeyError` inside Ash-core `scope_refs` (Ash 3.29.3),
  before AshArcadic sees it; use a flat filter or load-then-filter pending the upstream fix.

## Calculations (Slice 7)

- **Expression calculations are first-class — load, filter-on, and sort-on.** A
  `calculate :full_name, :string, expr(first <> " " <> last)` loads, `filter(res,
  full_name == "…")` and `sort(res, full_name: :asc)` push down, and raw compound
  attribute expressions in a filter (`filter(res, a + b > 5)`) are expanded and pushed
  down. Module calculations and standalone `Ash.calculate/2` are unchanged.
- **Two compute paths, one supported set.** LOADED calcs compute in **Elixir** (Ash's
  evaluator over the flat `RETURN n`, so sensitive fields stay app-decrypted upstream);
  filter-on-calc, sort-on-calc, and raw filter-expansion translate to **Cypher** via the
  `AshArcadic.Query.Expression` value translator (WHERE / ORDER BY only). The supported
  expression set is identical across all three paths.
- **Supported operators/functions:** arithmetic `+` `-` `*` `/`, concat `<>`, comparison
  (`==` `!=` `>` `<` `>=` `<=`), boolean `and`/`or`/`not`, `if`/`cond` (→ Cypher `CASE`),
  `is_nil`, `string_downcase` / `string_length` / `length` / `string_trim` / `round`
  (single-argument `round/1` only — `round(x, precision)` fails closed), and `contains` /
  `string_starts_with` / `string_ends_with`. A comparison may carry a compound value
  expression on **either** side (`a + b > 5`, `a > b + 1`, `first <> last == "…"`). Anything
  else (date/time functions like `ago`/`now`, `fragment`, `type` coercions, relationship-path
  calcs) fails closed value-free (`%UnsupportedFilter{}` naming the operator/field).
- **Division is float, matching Ash.** `a / b` emits `toFloat(a) / b` so integer operands
  divide like Ash (`7 / 2 == 3.5`), NOT ArcadeDB's integer truncation (`7 / 2 → 3`) — the
  filtered set matches the loaded value.
- **A `sensitive` or non-stored field in a calc expression fails closed value-free on ALL
  paths** (load, filter, sort). The data layer only ever holds the STORED value, and a
  `sensitive` field is app-side-encrypted ciphertext (AshCloak decrypts above the data
  layer) — evaluating a calc over it is both wrong and a redaction-leak surface. For a
  derived value over a sensitive field, use a **module calculation** (computed above the
  data layer, post-decrypt).
- **Relationship-path calcs fail closed on ALL paths.** A calc referencing a related node
  (`expr(author.name)`) is rejected value-free on load, filter, AND sort — the load path
  never routes it through Ash's `authorize?: false` relationship-load fallback, so it cannot
  read a related resource around its row/field policies. Relationship calculations are a
  future (traversal-calc) concern.
- **Field-policy interaction.** A calc referencing a field-policy-protected (non-`sensitive`)
  field in a filter/sort inherits AshArcadic's flat-field-filter behavior — the data layer
  has no actor at translate time, the same documented class as the `exists`-oracle (an
  upstream Ash concern, not data-layer-fixable).
- **Sort nil-placement is faithful.** All four Ash qualifiers are honored: `:asc`/`:desc`
  use ArcadeDB's native placement (ASC → nulls last, DESC → nulls first, matching Ash's
  default convention); the explicit opposites `:asc_nils_first` / `:desc_nils_last` are
  honored with a leading `(<col> IS NULL)` sort key.
- **Load/filter parity boundary.** Pushed filter/sort computation runs in ArcadeDB and matches
  the Elixir-loaded value on the common paths, but three edges diverge because Cypher cannot
  reproduce Elixir's exact semantics: (1) a calc whose **declared type coerces** its
  expression in a value-changing way (a non-natural type, e.g. `:string` over an integer
  expression) — the load casts, the pushed filter/sort does not (a `type`-coercion non-goal;
  use the natural declared type or a module calc); (2) `round/1` at exact **negative
  half-integers** — Ash rounds half away from zero (`-2.5 → -3`), ArcadeDB half toward `+∞`
  (`-2.5 → -2`); (3) **division by zero** — loading returns a value-free error (the calc eval is
  rescued), while the pushed filter yields ArcadeDB `Infinity` (row included). For guaranteed
  parity on these edges, compute via a module calculation.

## Aggregates (Slice 3, Plan 1)

- **Supported kinds:** `Ash.count / sum / avg / min / max / first / list / exists?` and
  `Ash.aggregate` (including `uniq?`), plus offset-pagination `count: true`. Each aggregate
  runs as **one parameterized Cypher statement**, **tenant-scoped fail-closed** — the same
  posture as reads: a `:context` blank tenant errors (never a base-database read), and an
  `:attribute` resource rides Ash-core's injected discriminator filter. A **per-aggregate
  filter** is honored (ANDed onto the tenant scope); an unpushable per-aggregate filter fails
  closed (`UnsupportedFilter`), never a silently unscoped aggregate.
- **Empty (and all-null-field) sets return Ash's per-kind default, not ArcadeDB's.** `sum` /
  `avg` / `min` / `max` / `first` over a set with no non-null field values → `nil` — a
  `count(n.<field>)` non-null-count companion disambiguates it from ArcadeDB's `sum → 0`
  (matching Ash/SQL null-skipping); `count → 0`; `list → []`. A caller-supplied `default` is
  honored.
- **Storage-class guard (fail-closed value-free).** `sum` / `avg` require **numeric** storage
  (`:integer` / `:float`) — rejected over `:decimal` (exact-string; ArcadeDB `sum`/`avg` would
  concatenate/error) and every non-numeric type. `min` / `max` / `first` require
  **order-preserving** storage — rejected over `:binary` and `:decimal` (same D27 reason
  sort is restricted). `list` rejects **`:binary`** (an encrypted-binary / `sensitive`
  attribute would otherwise return ciphertext into the result). `count` / `exists?` are always
  allowed. A rejected aggregate names only the field + kind — never a value.
- **Unsupported (this flat/query path):** flat inline field aggregates (`add_aggregates` over a
  non-relationship) and lateral joins are **not** supported (ArcadeDB has no window functions).
  **Custom** aggregate kinds are unsupported. `include_nil?: true` on `list` / `first` is
  **unsupported on this flat path** (ArcadeDB `collect` drops nulls) — it fails closed value-free
  (the **traversal** aggregate path below *does* honor it). **Relationship aggregates over a manual
  `Traverse` relationship ARE supported** as of Slice 4 — see *Traversal aggregates* below; but a
  **standalone** `Ash.aggregate` over a relationship path is rejected value-free (load it inline).

## Traversal aggregates (Slice 4)

- **Declare** an aggregate over a manual `Traverse` relationship in an `aggregates do … end`
  block — e.g. `aggregates do count :descendant_count, :descendants end` — for any kind
  (`count`/`sum`/`avg`/`min`/`max`/`first`/`list`/`exists`). It computes over the node's
  **reachable subtree** (what the `Traverse` relationship reaches).
- **Computed POST-authorization, in Elixir** — never a DB-side Cypher aggregate. The subtree is
  loaded through one batched authorized `Ash.load` (Traverse's `UNWIND $ids`, not N+1) threading the
  **real `authorize?`/`actor`/`tenant`**, then folded in `AshArcadic.TraversalAggregate` over the
  already-authorized, **node-deduped**, tenant-scoped, filtered, sorted destinations. Consequences a
  DB-side aggregate would get wrong: a **policy-denied intermediate drops its entire subtree** (a
  destination reachable only through a denied hop is not counted), a **cross-tenant node is not
  counted**, and multi-path nodes are deduped (no double-count for `sum`/`avg`).
- **`include_nil?` is honored** for traversal `list`/`first` (Elixir null control) — the asymmetry
  vs. the flat aggregate path above (which fails it closed because Cypher `collect` drops nulls).
  Empty / all-null-field sets return the aggregate's Ash default; the same value-free storage-class
  guard applies (`sum`/`avg` numeric; `min`/`max`/`first` order-preserving; `list` rejects `:binary`).
- **Load it inline** (`Ash.read(load: [:descendant_count])` / `Ash.load(record, :descendant_count)`).
  A **standalone** `Ash.aggregate` over a relationship path is **rejected value-free** — its cross-row
  collapse semantics are unresolved; the per-node subtree rollup is delivered by the inline load path.
- **Not supported:** multi-segment relationship paths fail closed value-free (compose two authorized
  reads instead).

## Standard (attribute-FK) relationships (Slice 5)

- **A standard relationship is a property FK, not a graph edge.** `belongs_to` / `has_many` /
  `has_one` / `many_to_many` store the FK as a vertex property; Ash's core batched-`IN` loader
  (over AshArcadic's `run_query`) does the loading/aggregating — there is no new callback and no
  edge write. Use a **graph edge** (a manual `Traverse` relationship + edge-write) only when you
  need graph traversal semantics; use a **standard relationship** for ordinary FK associations.
- **A join/FK attribute must NOT be `sensitive`.** A `sensitive` attribute is app-side-encrypted
  binary and cannot be `IN`-joined; declaring one as a relationship join key fails the build
  (`ValidateRelationshipFk`, value-free). _Coverage boundary:_ the check is per-resource and local —
  it catches a sensitive `belongs_to` `source_attribute` and a sensitive join-resource FK directly.
  A `has_many`/`has_one` sensitive `destination_attribute` is caught only when the destination
  declares the idiomatic inverse `belongs_to`; a sensitive `destination_attribute` with no inverse
  is not caught at compile (a per-resource verifier cannot read a sibling's `sensitive` list) — its
  effect is a silently-empty load, not a leak. Don't mark a relationship FK `sensitive`.
- **Filtering across a relationship is fail-closed to authorizer-bearing destinations.** A
  source-on-related filter (`filter(Post, author.name == x)`) routes through Ash's separate-read
  IN-rewrite, which reads the DESTINATION **without** per-hop authorization. To prevent an
  unauthorized row-policy bypass / field-policy oracle, AshArcadic **rejects** (`"not filterable"`,
  for every actor including admin) filtering across a relationship whose destination resource
  carries any authorizer. Filter against a destination with no authorizer, or filter/load the
  destination directly. **Loading and aggregates are unaffected** — they apply authorization
  correctly. (Tenant isolation always holds on every delegated read.) _Known limitation (Ash-core, not
  data-layer-fixable):_ the `exists(rel, …)` path is NOT gated by this guard — Ash decomposes a related
  `exists` into flat reads before the data layer sees it, so there is no capability/translator hook, and
  the one data-layer lever (rejecting any `internal?` read over an authorizer-bearing resource) was tried
  and **reverted** because it also rejects legitimate relationship-referencing read policies
  (`relates_to_actor_via` / `accessing_from` / `authorize_if expr(exists(rel, …))`). Do NOT rely on
  `exists` over a relationship to a policy-protected field; the proper fix is an upstream Ash-core hook.
- **Filtering across a manual `Traverse` relationship is unsupported** (fail-closed, `"not
  filterable"`) — its per-hop authz cannot be preserved by the IN-rewrite.
- **Filtering a source on a `many_to_many`-related field is unsupported.** `filter(Tag, posts.title
  == x)` is rejected — by Ash-core (`"cannot access multiple resources for a data layer that can't be
  joined…"`) when the endpoint has no authorizer, or earlier by the fail-closed rule above (`"not
  filterable"`) when it does — because a m2m filter crosses the join resource and AshArcadic advertises
  no join. Load the m2m and filter in memory, or use a standalone read. **m2m loading and aggregates
  work.**
- **Filter-on-aggregate is unsupported** (`filter(res, some_agg > n)`) — it fails closed value-free
  (`%UnsupportedFilter{}`); an aggregate is a computed fold value, not a stored property.
- **Index FK properties for large relationships (performance).** A relationship load/filter resolves
  through `WHERE dest.<fk> IN [<source_pks>]`; without an ArcadeDB index on the FK property this is a
  full-label scan. For large destination sets, add an index on the FK property in your host-app
  `arcadic` migration (as you would the primary key).

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

## Traversal (Plan 4; upgraded in Slice 2, Plan 2 — spec §7)

- **Bounded graph reach as a manual relationship.** Declare a `has_many` whose
  `manual` is `AshArcadic.ManualRelationships.Traverse` to traverse edges:

      has_many :descendants, MyApp.Node do
        manual {AshArcadic.ManualRelationships.Traverse,
                edge_label: :PARENT_OF, direction: :outgoing, min_depth: 1, max_depth: 3,
                scope_edges: true}
      end

  `edge_label` is required and identifier-validated; `direction` is
  `:outgoing | :incoming | :both`; `max_depth` is a required integer ≥ 1 (unbounded
  `*` is forbidden); `min_depth` defaults to 1; `scope_edges` defaults to `true`
  (see edge scoping below). The **destination resource must have a single-attribute
  primary key** (composite → fail-closed value-free). Loading the relationship returns
  the reachable **and authorized** destination records, deduped per source,
  cardinality-aware.
- **Edge writes landed in Slice 2** (see "Edge writes" below). Traversal also reads
  edges written out-of-band (host-app ingestion / raw `arcadic` Cypher).
- **Traversal is fail-closed multitenant.** A blank tenant runs no query. `:context`
  traversal is physically scoped to the tenant's database (no cross-tenant reach).
  `:attribute` traversal scopes **every node on the path** via the native predicate
  `ALL(x IN nodes(p) WHERE x.<attr> = $tenant)` — an in-tenant node reachable only
  through an out-of-tenant intermediate is **excluded**, not just the endpoints.
  Traversing between two `:attribute` resources with **different** discriminators
  fails closed (`:mixed_attribute`) — one tenant value cannot honor two dimensions.
- **Edge-property scoping is DEFAULT-ON for `:attribute`.** In addition to node
  scoping, the path predicate also scopes **every edge** via
  `ALL(r IN relationships(p) WHERE r.<attr> = $tenant)`. Library-written edges carry
  the `<attr>` stamp (see "Edge writes"), so this is fail-closed: an out-of-band edge
  **lacking** the stamp is *excluded* (never silently traversed into a cross-tenant
  reachability leak). Opt out with **`scope_edges: false`** for graphs whose edges are
  written out-of-band and rely on node-structure scoping only. `:context` traversal
  needs no edge scoping (physical DB isolation).
- **Traversal delegates filter / sort / row-policy / field-policy to standard authorized
  reads (Option B, spec §7.2 — resolves the Plan-4 CV1 carry).** The traversal is a
  three-step primitive: (1) a tenant-scoped reachability query returns each source's
  reachable paths as **node-PK lists** (scoping the whole path — nodes + edges); (2) two
  authorized `Ash.read`s — **Read A** authorizes every path node by **row policy**, then
  **Read B** reads the surviving destinations through the caller's `context.query` (its
  **filter + sort**), applying row policy, **field policy** (redaction), and the tenant
  filter / database; (3) regroup per source. The tenant boundary is enforced **twice over**
  (the path predicate + the reads' `:attribute` filter / `:context` database), both
  fail-closed. **Ash rejects *dynamic* `limit`/`offset` on manual relationships** (it raises
  `Ash.Error.Load.InvalidQuery`), so a traversal relationship cannot be loaded with a caller
  limit; for a bounded per-source result use the static **`per_source_limit`** /
  **`per_source_offset`** opts (below), or a downstream read/pagination over the loaded set.
- **Authorization is PER-HOP (row policy on every node of the path).** Read A authorizes
  **every node on each path** (destinations *and* intermediates) by row policy; a destination
  is returned only if it has a path whose **every** node is authorized. So a destination
  reachable **only** through a row-policy-denied intermediate is **dropped** (the intermediate
  is never returned); a destination with any fully-authorized path survives. The caller's
  destination **filter** (Read B) selects/shapes which destinations to return — it does **not**
  block traversal *through* a filtered-out but authorized intermediate. This covers
  **self-referential** traversal (the shipped norm). A path through an intermediate of a
  **different resource** carrying a **different** policy is a Slice-3 concern and **fails
  closed** here (such a destination is dropped). Field-policy redaction still applies to the
  returned destinations.
- **Per-source limits are STATIC manual opts (Slice 3, Plan 2).** `per_source_limit`
  (a positive integer, default `nil` = unbounded) and `per_source_offset` (a non-negative
  integer, default `0`) on the manual `Traverse` opts cap each source's reachable destinations
  at a per-source top-N, sliced `offset..+limit` **by the relationship's own `sort`**. The slice
  is **output-shaping applied AFTER per-hop authorization and the caller sort** (in `regroup`,
  over the already-authorized Read-B destinations) — **not a query-cost bound**: Read B still
  reads the full authorized union first, so the top-N is by rank among the *authorized*
  destinations and a policy-denied destination **never consumes a slot**. `per_source_limit` and
  `per_source_offset` are **meaningless on a `:one` relationship and rejected value-free**. These are static because Ash
  rejects *dynamic* limit/offset on manual relationships (above); declare them on the resource's
  manual opts, e.g. `manual {AshArcadic.ManualRelationships.Traverse, edge_label: :KNOWS,
  max_depth: 3, per_source_limit: 10}` with the relationship's `sort` setting the ranking.

## Edge writes (Slice 2, Plan 1)

- **Declare an edge** in the `arcade do … end` block, then wire a change on a
  create/update action:

      arcade do
        client MyApp.Client
        label :Person
        edge :friends do
          label :KNOWS
          direction :outgoing          # :outgoing (default) | :incoming | :both
          destination MyApp.Person      # must have a single-attribute primary key
          properties [:since]           # optional edge-property keys
          # multiple? false             # default → idempotent MERGE; true → parallel CREATE
        end
      end

      actions do
        update :befriend do
          require_atomic? false          # the change is a non-atomic after_action
          argument :to, {:array, :string}
          argument :since, :string
          change {AshArcadic.Changes.CreateEdge, edge: :friends, to: :to}
        end

        update :unfriend do
          require_atomic? false
          argument :to, {:array, :string}
          change {AshArcadic.Changes.DestroyEdge, edge: :friends, to: :to}
        end
      end

- **`to:` names an argument** holding the destination PK (or a list → N edges;
  nil/empty → no edge, the action still succeeds). Edge **property values come from
  same-named DECLARED action arguments**, serialized by the argument's declared type.
- **Writes run in the action's transaction** (an `after_action` hook). A failed or
  0-row edge write returns `{:error, _}` so Ash rolls the vertex back; a mid-list
  failure rolls **all** edges back (not a partial write). DB errors are redacted.
- **`multiple?` selects the primitive.** `false` (default) → `MERGE` — idempotent, one
  edge per endpoint-pair + label (a repeat `befriend` updates the edge's properties, no
  duplicate). `true` → `CREATE` — parallel edges (each write is a new edge).
- **Single-attribute destination PK required.** Edge destinations must have a
  single-attribute primary key (the endpoint match binds `b.<pk> = $dst`).
- **Fail-closed multitenant.** For an `:attribute` resource, both endpoints are scoped
  by the tenant discriminator in the `WHERE` *before* the MERGE/CREATE/DELETE
  rel-pattern (never inlined into a node pattern), and the discriminator is stamped
  onto the edge. A same-PK destination in another tenant is **not** bound — a
  cross-tenant edge write 0-rows (`InvalidRelationship`); a cross-tenant edge delete
  0-rows (`StaleRecord`). Deleting an absent edge also fails closed as `StaleRecord`.
- **Sensitive edge properties (R4).** An `edge` `properties` key naming a `sensitive`
  attribute requires every same-named action argument to be **binary-storage-typed**
  (`:binary`), else the classified datum would reach edges as plaintext. Enforced at
  compile time (`ValidateSensitive` R4) and at runtime (`CreateEdge` fails closed,
  value-free, on an undeclared/plaintext argument). Edge property values are
  **full-param encode-gated** (Rule 4) before the DB touch — a raw non-UTF8 binary
  nested in a `:map`/`:list` property fails closed value-free, naming only the key.

See `docs/CHARTER.md` for architecture and the open multitenancy decision; `AGENTS.md`
for the full working rules.
