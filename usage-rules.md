# ash_arcadic usage rules

_An Ash DataLayer for ArcadeDB (native OpenCypher over HTTP)._

> The full 0.1.0 surface is live: the `arcade do ... end` DSL section, query
> compilation (filter/sort/distinct/combinations), CRUD + upserts + atomics,
> bulk writes, offset + keyset pagination, aggregates, calculations,
> relationships + traversal + edge writes, vector search (dense/sparse/hybrid),
> transactions, `:async_engine`, and telemetry — all fail-closed multitenant.
> The binding facts, per feature:

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

## CDC mirror — Postgres→ArcadeDB effect-once sink (`AshArcadic.Replicant.*`)

An **optional** subsystem that mirrors a Postgres logical-replication stream into an
ArcadeDB graph projection **exactly once**, over the sibling `replicant` CDC transport. Opt-in
— a host that does not use CDC never references these modules. `replicant` is an `optional: true`
dep, but the whole `AshArcadic.Replicant.*` subtree hard-references `%Replicant.*{}` structs at
compile, so **a host that uses the CDC sink MUST add `replicant` to its own deps** (a host that
does not never compiles it).

- **Declare a mirror resource** with the `AshArcadic.Replicant` extension. `source_table` is
  required (no reflection — a graph resource's `arcade` label is not its Postgres table);
  `source_schema` defaults to `"public"`; `tenant_attribute` names the SOURCE column carrying the
  tenant (resolved per row, passed as `tenant:` to the mirror write); `skip` names **source**
  (Postgres) columns excluded from the mirror (distinct from `arcade do skip … end`, which names
  target attributes); `on_truncate` is `:halt` (default) or `:mirror`.

      defmodule MyGraph.Order do
        use Ash.Resource,
          domain: MyGraph.Domain,
          data_layer: AshArcadic.DataLayer,
          extensions: [AshArcadic.Replicant],
          authorizers: [Ash.Policy.Authorizer]

        arcade do
          client MyGraph.ArcadicClient
          label :Order
        end

        replicant do
          source_table "orders"
          # source_schema "public"      # default
          tenant_attribute :org_id
          skip [:internal_notes]        # source columns excluded from the mirror write
          on_truncate :halt             # default (fail-closed); or :mirror
        end

        attributes do
          attribute :id, :string, primary_key?: true, allow_nil?: false
          attribute :org_id, :string
          attribute :title, :string
          # ...
        end

        multitenancy do
          strategy :attribute           # NEVER :context (see the single-database rule)
          attribute :org_id
        end

        actions do
          # The sink calls the resource's PRIMARY create + destroy. A defaults-generated
          # :destroy is primary; a custom create must be marked primary? true.
          defaults [:read, :destroy]

          create :upsert do
            primary? true
            upsert? true
            accept [:id, :org_id, :title]
          end
        end

        # The seam-lock: forbid ordinary writes so only the sink writes (bypassing with
        # authorize?: false). A resource with write actions and NO authorizer fails to compile.
        policies do
          policy always() do
            forbid_if always()
          end
        end
      end

- **Wire the checkpoint, sink, and pipeline.** The checkpoint is an ArcadeDB-resident watermark
  vertex (one row per slot); the sink is a `Replicant.Sink` impl baked with the host's config; the
  pipeline is a supervision child that starts `replicant` with the correct start-mode.

      defmodule MyGraph.Checkpoint do
        # The watermark vertex (label :ReplicantCheckpoint, integer last_commit_lsn). Its
        # `client:` MUST target the SAME ArcadeDB database as the mirror resources.
        use AshArcadic.ReplicantCheckpoint,
          domain: MyGraph.Domain,
          client: MyGraph.ArcadicClient
      end

      defmodule MyGraph.ReplicantSink do
        use AshArcadic.ReplicantSink,
          domains: [MyGraph.Domain],
          checkpoint_resource: MyGraph.Checkpoint,
          slot_name: "mygraph_orders"
      end

      # In your supervision tree:
      children = [
        {AshArcadic.Replicant.Pipeline,
         connection: [hostname: "standby.internal", port: 5432, username: "u",
                      password: "p", database: "evidence", ssl: true],
         publication: "orders_pub",
         sink: MyGraph.ReplicantSink}
      ]

  The `:sink` carries `slot_name` + `domains` + checkpoint (the single source of truth); the host
  supplies only `:connection` and `:publication`. On an **empty** checkpoint the pipeline runs a
  full **snapshot** bootstrap (the rebuildable-projection premise — forward-only replay would lose
  every pre-slot row); on a durable watermark it **resumes**. A mis-mapped mirror (duplicate/missing
  `source_table`) fails the host's boot loud, never silently starts. Postgres logical-replication
  setup (`wal_level=logical`, the slot, the publication) is the host's operational concern.

**The seven fail-closed contracts a consumer MUST honor** (verifier-enforced or runtime-halted):

1. **Single-database (compile verifier).** A mirror resource must be `:attribute` multitenancy or
   non-multitenant — **never `:context`**. Effect-once needs every tenant a tenant-blind Postgres
   transaction can touch to live in ONE ArcadeDB database; `:context` maps tenants to different
   databases, so a cross-tenant Postgres transaction would fail `:cross_database_transaction` and
   shatter effect-once. `ValidateSingleDbTenancy` rejects `:context` at compile. The checkpoint's
   `client:` MUST also resolve to that same database (not verifier-checkable — the checkpoint is not
   a mirror resource; a mismatched client makes the watermark upsert a cross-database write that
   fails the session).

2. **Sensitive source columns must be skipped (compile verifier + runtime halt).** AshArcadic holds
   no key material, so it cannot safely emit an arriving Postgres value into an encrypted-binary
   column. A non-`skip`ped source column whose name matches a `sensitive` target attribute **HALTS
   the transaction value-free** (`:sensitive_plaintext`) at apply time — so list every such column in
   the `replicant` `skip`. (If a column genuinely arrives already-ciphertext and you want it
   mirrored, model the target as a plain `:binary` attribute, NOT `sensitive` — the
   searchable-encryption escape hatch; `sensitive` is the do-not-mirror-as-plaintext contract.) A
   `sensitive` **primary key** is additionally rejected at compile
   (`ValidatePrimaryKeyNotSensitive`) — the sink builds the mirror identity from the source's
   plaintext key to MATCH the vertex, and a sensitive PK would both leak the value and break
   idempotent matching.

3. **Write-action seam-lock (compile verifier + consumer policy).** A mirror resource with any
   create/update/destroy action **must declare at least one authorizer**
   (`ValidateWriteActionsAuthorized` rejects the absence at compile — the sound compile-time
   precondition). That verifier is necessary but NOT sufficient: the FULL forbidden-by-default lock
   is **your** default-deny policies (e.g. `forbid_if always()`) plus the sink's `authorize?: false`
   bypass. A **permissive** write policy defeats the lock (any caller could dual-write the mirror)
   and is **the consumer's responsibility** — it is compile-undecidable (a runtime SAT problem), so
   cover it with your own policy tests.

4. **Effect-once via a same-transaction integer watermark.** The watermark is an **integer** LSN
   stored in the same ArcadeDB database, advanced in the **same `Ash.transaction`** (one session) as
   the mirrored writes — so data + watermark commit atomically or roll back together. A replayed
   `commit_lsn` is a no-op via the integer `<=` gate (`is_integer(stored) and lsn <= stored`); a
   `nil`/never-applied checkpoint **applies** (the guard is load-bearing — in Erlang term order a
   number sorts before every atom, so a guardless `lsn <= nil` would wrongly skip the first
   transaction). A crash mid-apply commits neither the data nor the watermark, so `replicant`
   redelivers from the last acked LSN (loss = 0); `MERGE` upsert makes any individual re-apply
   idempotent (dup = 0).

5. **Empty-index fails closed.** A sink whose `domains` contain NO replicant mirror resource fails
   closed (`:empty_index`) BEFORE opening the transaction — it never silently skips every change while
   advancing the watermark (which would be permanent, invisible loss). A non-empty index with a
   specific unmapped `{schema, table}` stays a legitimate partial-publication skip (`:ok`).

6. **Truncate.** An upstream `TRUNCATE` is handled per `on_truncate`: `:halt` (default, fail-closed —
   the transaction rolls back) or `:mirror` (a tenant-**blind** whole-label `DETACH DELETE`, atomic
   with the surrounding changes and the watermark advance).

7. **Optional-dep caveat (honest optionality).** `replicant` is declared `optional: true`, but the
   `AshArcadic.Replicant.*` subtree hard-references `%Replicant.Transaction{}` / `%Replicant.Change{}`
   structs at compile, so it is **not** conditionally compiled. A host that uses the CDC sink **must
   add `replicant` to its own deps**; a host that doesn't never touches these modules and needs
   nothing.

- **Value-free CDC telemetry.** Two flat events —
  `[:ash_arcadic, :replicant, :transaction, :apply]` (measurements `change_count`, `duration`) and
  `[:ash_arcadic, :replicant, :transaction, :skip]` (measurement `duration`, a replay-gate hit) —
  carry metadata `slot` + `commit_lsn` ONLY. No row value, record, column, or tenant ever reaches an
  error or telemetry.

## Vector search — dense, sparse & hybrid (Slice 10)

- **Declare the index in the `arcade` block; the HOST creates it.** `vector_index :embedding,
  dimensions: 384, similarity: :cosine` is metadata only (the `Type[property]` reference + distance
  semantics + compile validation) — ash_arcadic has no migration/DDL machinery. Create the actual
  index in your app: `Arcadic.Vector.create_dense_index!(conn, "Label", "embedding", 384,
  similarity: :cosine)`. A `vector_index` attribute must be a STORED, NON-`sensitive`, array-typed
  property (verified at compile — a float-array index cannot be encrypted-binary, and encryption would
  break the index).

- **Search is a normal read action + a preparation** (dense kNN is ArcadeDB SQL `vector.neighbors`, a
  separate path from the Cypher engine — not a filter/sort):

  ```elixir
  read :semantic_search do
    argument :query_vector, {:array, :float}, allow_nil?: false
    argument :k, :integer, allow_nil?: false
    prepare {AshArcadic.Preparations.VectorSearch, index: :embedding}
  end
  ```

  `Ash.Query.for_read(Resource, :semantic_search, %{query_vector: v, k: 10}) |> Ash.Query.set_tenant(t)
  |> Ash.read()`. Results are records ranked closest-first; the distance rides
  `record.__metadata__[:vector_distance]`. Pass `ef_search`/`max_distance` as preparation options.

- **Sparse (learned-sparse / BM25-style) kNN** — declare a `sparse_vector_index` over a `(tokens,
  weights)` attribute PAIR (an integer array + a float array; BOTH stored, non-`sensitive`,
  array-typed — verified at compile), and attach the preparation with `kind: :sparse`:

  ```elixir
  arcade do
    sparse_vector_index :sparse_embedding, tokens: :tokens, weights: :weights
  end

  read :sparse_search do
    argument :query_tokens, {:array, :integer}, allow_nil?: false
    argument :query_weights, {:array, :float}, allow_nil?: false
    argument :k, :integer, allow_nil?: false
    prepare {AshArcadic.Preparations.VectorSearch, kind: :sparse, index: :sparse_embedding}
  end
  ```

  Host-creates the index: `Arcadic.Vector.create_sparse_index(conn, "Label", "tokens", "weights")`.
  Sparse results rank by a **`score`** (higher = better) on `record.__metadata__[:vector_score]` (no
  `distance`). Sparse passthrough opts are `group_by`/`group_size` only (`ef_search`/`max_distance`
  do not apply).

  > **⚠️ Sparse retro-index caveat (silent).** An ArcadeDB sparse index does NOT cover rows that
  > existed BEFORE it was created — only rows inserted/updated afterwards are searchable — and the
  > coverage signal fires at index-CREATE time, not at query time. **Create the sparse index BEFORE
  > loading data**, or re-touch pre-existing rows. A query over uncovered rows silently returns fewer
  > results, with no error.

- **Hybrid fusion** — combine ≥2 arms (dense / sparse / full-text) into one fused ranked list via
  `kind: :hybrid`. Arms name the indexes/properties (developer config); the caller passes the query
  values. The full-text arm's property needs a host-created full-text index
  (`Arcadic.FullText.create_index`); its declaration surface is a later slice, but the fuse ARM ships now.

  ```elixir
  read :hybrid_search do
    argument :query_vector, {:array, :float}, allow_nil?: false
    argument :query_tokens, {:array, :integer}, allow_nil?: false
    argument :query_weights, {:array, :float}, allow_nil?: false
    argument :text_query, :string, allow_nil?: false
    argument :k, :integer, allow_nil?: false

    prepare {AshArcadic.Preparations.VectorSearch,
             kind: :hybrid,
             arms: [{:dense, :embedding}, {:sparse, :sparse_embedding}, {:fulltext, :body}],
             fusion: :rrf}
  end
  ```

  `fusion` is `:rrf` (default) | `:dbsf` | `:linear`; `weights`/`group_by`/`group_size` pass through;
  a single `k` bounds every arm and the fused output. Fused rows rank by `score`
  (`record.__metadata__[:vector_score]`).

- **Tenant-scoped, fail-closed, by default (ALL kinds).** `:context` runs the kNN in the tenant's physical DB;
  `:attribute` two-phase-scopes it — ash_arcadic SELF-INJECTS the tenant predicate (never trusting
  Ash's own filter, so a `:bypass` action cannot leak), pre-queries the scoped `@rid`s, and passes them
  as the native candidate set. The SAME candidate set scopes sparse and **every hybrid arm, including
  the full-text arm** (mutation-proven live). A no-tenant search fails closed (`tenant required`).
  Caller/row-policy filters compose (a denied/filtered row never enters the candidate set).

- **Cross-tenant search is a deliberate TWO-part opt-in.** BOTH the Ash action must permit the
  no-tenant read (`multitenancy :allow_global` or `:bypass`, or a `global?` resource) AND the
  preparation must set `allow_global?: true`. One without the other either rejects upstream
  (`TenantRequired`) or stays tenant-scoped. `allow_global?` is `:attribute`-only (`:context` has no
  cross-DB "global" target). A non-multitenant resource searches globally (no tenancy to enforce).

- **Cardinality ceiling (`:attribute`).** The candidate set materializes the tenant's matching `@rid`s;
  a set larger than `max_vector_candidates` (default 10 000, `config :ash_arcadic,
  :max_vector_candidates`) fails closed — **never truncates** (truncation would silently drop the true
  nearest neighbour). For very large tenants prefer `:context` (physical isolation) for vector search.

- **Params-only + value-free.** The query vector/tokens/weights/text, `k`, and the tenant value all
  bind as `$param`; no query value ever reaches an error or telemetry (the read span carries only
  value-free `vector_search?` + `vector_kind` tags). A malformed stash (crafted via `set_context`)
  fails closed value-free — never a leak.

## Keyset pagination, `:async_engine` & read-path redaction (Slice 11)

- **Keyset pagination + `Ash.stream!`.** `can?(:keyset)` is advertised, so `Ash.read(query, page:
  [after: cursor, limit: n])` / `page: [before: cursor, …]` and `Ash.stream!` use efficient cursor
  pagination instead of offset re-scans. Ash builds the compound cursor filter itself (`(sort > $c)
  OR (sort = $c AND pk > $i)`) — a normal filter AshArcadic already translates — and computes each
  record's cursor from its sort-field values; the data layer just advertises the capability and
  implements `data_layer_keyset_by_default?/0 → false` (the callback that routes to Ash's fallback
  cursor path). `page: [count: true]` returns the tenant-scoped total.
- **Supported keyset-sort set.** Any **stored, comparable** sort attribute: `:integer`, `:float`,
  `:boolean`, `:string`, and the datetime/time family (`:utc_datetime`, `:naive_datetime`, `:time`,
  incl. `precision: :microsecond`). A duplicate-value sort resolves deterministically via the primary
  key tiebreaker. **Fail-closed (never silently mis-page):** a `:binary`(sensitive)/`:decimal` sort,
  and a COMPOSITE-typed sort (`:map`, `:struct`, `:union`, `{:array, _}` — no total order), are
  rejected `UnsortableField` at the sort gate; a non-stored / calc / aggregate sort is rejected
  value-free `UnsupportedFilter` on the cursor page (the filter guard). Keyset over a **combination**
  query is supported (the cursor lands in the outer filter).
- **Keyset limitations inherited from Ash core** (not data-layer-fixable): (a) if you provide an
  `after:`/`before:` cursor whose shape doesn't match the query's sort, Ash's `InvalidKeyset` error
  interpolates the (decodable) cursor — it echoes YOUR OWN prior-page sort values, not another
  tenant's, but avoid logging that error verbatim; (b) a keyset sort over a field a non-admin actor
  cannot read (field policy) breaks on page 2 — Ash computes the cursor from the redacted
  `%Ash.ForbiddenField{}`. Sort keyset pages by a field the actor can read.
- **Perf is bounded MEMORY, not bounded time.** Keyset's win here is streaming without an unbounded
  in-memory read; it is NOT necessarily faster than offset per page — AshArcadic has no sort-index
  DSL, so ArcadeDB full-scans + sorts each page over an unindexed sort field. Add a host-side index on
  the sort field if you need deep-pagination speed.
- **`:async_engine` — concurrent reads/loads.** `can?(:async_engine)` is advertised (probe-verified
  pool-safe): Ash runs INDEPENDENT relationship/aggregate loads concurrently on a read (each its own
  pooled connection; a transactional action still runs sync). This is always safe and deterministic —
  the marquee async value.
- **Concurrent bulk writes: use `transaction: false` — they CONVERGE.** Advertising `:async_engine`
  also lets `Ash.bulk_*` run batches concurrently when you pass `max_concurrency > 1`. On ArcadeDB,
  concurrent writes to one vertex type contend on that type's **buckets** (optimistic-lock
  `ConcurrentModificationException`). Every AshArcadic AUTOCOMMIT write statement retries the
  conflict at TWO levels — ArcadeDB's server-side statement retry (arcadic's `retries:` body param)
  plus a client-side jittered-backoff retry — both idempotency-safe by construction (an autocommit
  statement is all-or-nothing; nothing was applied on the failed attempt) and Ash hooks are NEVER
  re-fired (the retry lives below the data layer, around one HTTP command). So
  `Ash.bulk_create(rows, R, :create, transaction: false, max_concurrency: 8)` converges fully even
  on a default-bucket type (probe-verified: deterministic 80/80 across 10 runs; each batch is ONE
  `UNWIND` statement, so `transaction: false` costs no atomicity vs a single-statement session).
  **The default `transaction: :batch` opens a session per batch**, whose conflicts surface at COMMIT
  where no statement retry is safe (re-running would re-fire hooks) — under concurrency it can
  return `:partial_success`: there, pre-create hot types with buckets ≥ concurrency
  (`CREATE VERTEX TYPE X BUCKETS 32`, host-side; ArcadeDB caps ~32) and check
  `result.status`/`.error_count`. Retry knob: `config :ash_arcadic, :write_conflict_retries, N`
  (client attempts, default 5; 1 disables the client layer).
- **Read-path value-free redaction.** A non-encodable value in a read filter literal (a raw non-UTF8
  binary nested in a `:map`/`:list`) fails closed value-free — a `%QueryFailed{}` naming the failure
  CLASS, never the bytes — at every read wire site (flat, aggregate/count, combination, traversal,
  vector-candidate). Encode such values app-side (e.g. `Base.encode64`) or use a `:binary` attribute.

## Query-scoped bulk writes + atomics (Slice 9, Plan 1)

- **Query-scoped bulk update/destroy push down to ONE statement.** `Ash.bulk_update`/`Ash.bulk_destroy`
  over a query (`strategy: :atomic`) compile to a single parameterized Cypher `MATCH (n:Label) WHERE …
  SET …`/`DETACH DELETE n` — the tenant predicate, the caller filter, and the changeset filter are all
  ANDed into the WHERE (Ash pre-composes them into the data-layer query). Without this the operations
  still work via Ash's per-row `:stream` fallback; this is the efficient one-statement path
  (`can?(:update_query)` / `can?(:destroy_query)` / `can?(:expr_error)`).
- **Empty match is a NO-OP, not `StaleRecord`.** A query-scoped bulk update/destroy matching zero rows
  returns success with `[]` records — bulk semantics differ from the single-row pk-scoped `update`/`destroy`
  (which raise `StaleRecord` on a no-match).
- **Atomic expression updates push into Cypher `SET`.** `change atomic_update(:field, expr(field + 1))`
  (and cross-property refs, `if`/`round`, etc.) render as `n.field = <cypher>` via
  `AshArcadic.Query.Expression` — the RHS is hydrated then translated, every literal bound to a `$param`.
  A `sensitive`, non-stored, `:binary`, `:decimal`, relationship-path, or aggregate atomic RHS fails closed
  value-free (`%UnsupportedFilter{}`); an empty SET fails closed; the multitenancy discriminator is never
  settable (atomic OR static) — a write to it is rejected value-free (it would tenant-hop the row). The
  atomic **target** (LHS) is likewise guarded: a `sensitive` (app-side-encrypted) or non-stored target
  field is rejected value-free — an atomic binds its RHS raw (no serialization), so it must never write
  plaintext into an encrypted-binary column.
- **Atomic create/upsert are honest.** `change atomic_set(:field, expr(…))` on a create and an atomic
  change on an upsert action are applied (`can?({:atomic, :create|:upsert|:update})`): `create_atomics`
  fold into the `CREATE … SET …` — on a single create, a **bulk create**, and the **upsert `ON CREATE
  SET`** (the insert branch) — and `atomics` fold into the upsert `ON MATCH SET …`. (Advertising these
  without folding on ANY of those surfaces would silently DROP the atomic change — closed.)
- **Bulk destroy return-records captures pre-delete properties.** `return_records?: true` on a bulk
  destroy returns the deleted rows WITH their attributes (`… WITH n, properties(n) AS p DETACH DELETE n
  RETURN p`) — a post-delete read would yield no attributes.
- **`limit`/`offset`/`combination_of` on a query-scoped bulk write fail CLOSED.** A single `MATCH … SET`/
  `DELETE` cannot honor a per-row limit/offset (no ordering semantics) or a combination — a paged/combined
  bulk update/destroy returns a value-free error (use `strategy: :stream`), never a silent unscoped mutation.
  A conditional after-batch hook (`change …, where: […]`) on the action likewise fails closed (unsupported
  on the atomic path; use `:stream`).
- **Multitenancy is fail-closed on every bulk-write path.** `:context` — a blank tenant resolves no
  database, so no statement runs; `:attribute` — the discriminator predicate scopes the WHERE. A fabricated
  cross-tenant attacker cannot bulk-update/destroy another tenant's rows (mutation-proven).
- **Every value is a bound `$param`; errors are value-free.** Write-path params (static changes AND atomic
  RHS literals) are JSON-encode-gated before the wire — a poisoned value fails closed value-free, never a
  byte-leaking crash. (Read-path filter params are a separate, pre-existing gap — tracked outside this slice.)
- **Heterogeneous per-record bulk update (`update_many`, Slice 9 Plan 2).** `Ash.update_many/4` (a list of
  `{record, input}` tuples with `strategy: :atomic`) pushes a heterogeneous bulk update — each record its
  own changes — into ONE `UNWIND $rows AS r MATCH (n:Label {pk: r.pk}) [WHERE …] SET n += r.set[, <shared
  atomics>]` statement keyed by primary key. A record absent from the graph is simply absent from the
  result (never an error). Tenant scoping rides `opts.tenant`, never row data: `:context` targets the
  tenant database and fails closed on a blank tenant; `:attribute` injects the discriminator predicate. The
  group's shared `changeset.filter` (optimistic lock / atomic validation / policy) is AND-composed onto the
  WHERE, fail-closed on an untranslatable filter — symmetric with single-row `update`/`destroy`.
- **Multi-row bulk upsert (Slice 9 Plan 2).** A bulk `upsert? true` action (`upsert_fields` required by
  Ash) compiles to ONE `UNWIND $rows AS r MERGE (n:Label {<identity>: r.<identity>, …}) ON CREATE SET
  n += r.all[, <create atomics>] ON MATCH SET n += r.set[, <match atomics>]` statement — existing rows
  update, new rows create, idempotent, no duplicates. For an **`:attribute`** resource the tenant
  discriminator is added to the MERGE identity (D4), so a same-PK upsert from another tenant matches
  nothing and creates its own row (never hijacks). Atomic changes fold on BOTH branches (`create_atomics`
  → ON CREATE, `atomics` → ON MATCH); the discriminator is never in the ON MATCH set (D3). Every wire value
  is encode-gated value-free.
- **Concurrency caveat (inherent MERGE limit).** "No duplicates / idempotent" holds for SEQUENTIAL
  re-runs. ArcadeDB enforces no identity uniqueness, so two CONCURRENT bulk upserts of the SAME NEW
  identity can each MATCH nothing and both CREATE — duplicate rows. This is the same limitation as the
  single-row upsert; add a unique index or serialize writers if you need a hard guarantee.
- **`upsert_condition` is honored (single-row AND bulk).** The condition gates the ON-MATCH update
  against the EXISTING row's values: condition true → update applies; condition false → the update is
  SKIPPED — single-row default raises `StaleRecord`, `return_skipped_upsert?: true` returns the
  existing row flagged `__metadata__.upsert_skipped`; in bulk (without `return_skipped_upsert?`) a
  skipped row is OMITTED from the returned records (Ash's own bulk semantics), never an error. No
  matched row → plain CREATE (the condition gates ON MATCH only). Mechanics: a conditional upsert runs
  the Ash-reference three-step flow (conditional UPDATE through the tenant-scoped identity → existence
  probe → CREATE) instead of one MERGE — atomic under the action's transaction (Ash creates default
  `transaction?: true`); a conditional BULK upsert routes per-row through that flow (one statement per
  row, not one UNWIND). Tenancy holds: another tenant's same-PK row is never evaluated or mutated
  (mutation-proven). The condition's literals are encode-gated value-free like every write param.

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
- **Datetime/time comparisons work (`:utc_datetime`, `:naive_datetime`, `:time`, incl.
  `precision: :microsecond`).** ArcadeDB auto-coerces stored ISO8601 datetime/time strings to its
  native temporal types, so AshArcadic wraps the bound comparison param in the matching Cypher
  constructor (`datetime()` / `localtime()`) — equality, range (`gt/lt/gte/lte`) and `in` compare
  temporal-to-temporal, not string-to-coerced-value. `:date` needs no wrapper (ArcadeDB keeps
  date-only strings as strings). A **compound** temporal comparison (a temporal attr against a
  value-EXPRESSION RHS — an `if/3`, arithmetic, fragment) is NOT wrapped on the expression path, so it
  fails closed value-free (`UnsupportedFilter` naming the field) rather than silently mis-filtering —
  use a plain literal comparison, which IS wrapped.
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

## Distinct (Slice 8, Plan 1)

- **`distinct`/`distinct_sort` push down to native Cypher.** `Ash.Query.distinct(res, [:field, ...])`
  compiles to a DISTINCT-ON-subset render (`WITH n.<f> AS __d0, ..., collect(n)[0] AS n RETURN n`) —
  one whole vertex per distinct group, over stored, non-`sensitive` fields. Outer `sort`/`limit`/
  `offset` apply **after** the dedup. `limit` bounds the returned rows, not the DB-side dedup
  working set (the collect-group materializes every group's full vertex list before `[0]`) —
  filter narrowly on large labels.
- **Representative-row selection is via `distinct_sort`, else the query's `sort`.**
  `Ash.Query.distinct_sort(res, [...])` orders each group before `collect(...)[0]` picks the
  representative; with no `distinct_sort`, the query's `sort` selects it (Ash's documented
  fallback — "if none is set, any sort applied to the query will be used"). With neither, the
  representative is engine-arbitrary and the result rows carry no defined order (Ash promises
  none absent a sort; sibling data layers like ETS happen to return distinct-key order — rely
  on neither).
- **Aggregates over a distinct query fold the deduped representatives.** `Ash.count`, a
  `page: [count: true]` read, and value aggregates (`sum`/`min`/…) over a query carrying
  `distinct` dedup **before** folding — never the raw rows.
- **Dedup is per-tenant** under both multitenancy strategies (`:attribute` scoped by the
  discriminator in the shared database; `:context` physically isolated per-tenant database).
- **Fails closed value-free (`QueryFailed`, naming only the field)** on: a non-stored
  (`skip`-ped/computed) distinct field; a `sensitive` distinct field (random-IV ciphertext
  never dedups equal plaintext); a calculation or relationship-path distinct entry; and any
  sort direction outside Ash's six qualifiers
  (`:asc`/`:desc`/`:asc_nils_first`/`:asc_nils_last`/`:desc_nils_first`/`:desc_nils_last`) —
  `distinct_sort` reaches the data layer with no upstream validation, so the data layer rejects
  it itself. A `:binary`/`:decimal` field in the distinct list is not rejected by this data
  layer's guard (dedup is equality), but Ash core rejects it upstream (`UnsortableField`)
  before it reaches the data layer.
- **`distinct_sort` additionally rejects `:binary`/`:decimal` storage** (base64/lexicographic order
  ≠ value order, so the "first" row after ordering would be the wrong representative) — the same
  `can?({:sort, storage})` decision the record sort path already makes.

## Combinations (Slice 8, Plan 2)

- **`Ash.Query.combination_of(res, [Combination.base(...), Combination.union(...), ...])` is
  first-class.** All five types are advertised: `:base` (the required first branch),
  `:union`, `:union_all`, `:intersect`, `:except`. Combinations return **whole vertices**
  (no field-projection `select`); the set-op keys on the resource's **primary key**.
- **Two execution strategies, chosen automatically by the branch types** (surfaced by the
  `combination_strategy` telemetry tag):
  - **Native** (`:native`) when every branch is union-family (`:base`/`:union`/`:union_all`) →
    one `CALL { <branch> UNION[ ALL] <branch> } WITH n [WHERE <outer filter>] [distinct] RETURN n
    [ORDER BY/SKIP/LIMIT]` statement pushed to ArcadeDB (each branch's `$params` re-keyed into a
    disjoint namespace).
  - **In-memory** (`:in_memory`) when any branch is `:intersect`/`:except` (ArcadeDB has no
    `INTERSECT`/`EXCEPT`) **OR any branch carries a per-branch `limit`/`offset`** (paging forces the
    in-memory strategy so the tenant filter is applied to each branch **before** its limit) → each
    branch runs as its own query with the outer filter pushed in, then the results are folded by
    primary key in the app. `intersect`/`except`/paged combinations therefore fetch each branch's
    **full filtered result set** into memory before combining — filter narrowly.
- **The in-memory strategy is NOT a consistent snapshot.** Its branches are separate,
  non-transactional queries; a concurrent write between two branch reads can combine records from
  different database states (e.g. a row updated to fail the filter between the base and subtrahend
  reads of an `except`). The native path is a single atomic statement; the in-memory path matches the
  Ash ETS reference's sequential-per-branch semantics. A strongly-consistent read is not available for
  `intersect`/`except`/paged combinations this slice.
- **`:union` after `:union_all` deduplicates only the incoming branch against the accumulator** (the
  fold retains the accumulator's `union_all` duplicates), matching the Ash ETS reference. Appending an
  `intersect`/`except` to a union-family chain (which switches it to the in-memory strategy) therefore
  does not change what an earlier `union` deduplicated.
- **Multitenancy is enforced per branch.** `:context` requires every branch to resolve to the
  **same non-nil tenant database** — a blank tenant or branches spanning databases **fail closed
  value-free**. `:attribute` scoping rides the outer `query.filters` (Ash injects the tenant
  predicate on the outer combination query); it is applied by the native `CALL`-wrap `WHERE` and
  **pushed into every branch** on the in-memory path, so a cross-tenant primary-key collision can
  never enter the fold.
- **An outer `distinct` over a combination** renders the DISTINCT-ON collect-group on the union
  output but keeps an **engine-arbitrary representative** per group — it does **not** honor
  `distinct_sort` (the union output has no stable pre-collect order to select by).
- **Read-span telemetry** gains `combination?`, `combination_types` (the branch type atoms), and
  `combination_strategy` (`:native` | `:in_memory` | `nil`).
- **Fails closed value-free (`QueryFailed`)** on combination shapes this slice does not support:
  - a branch carrying **`calculations`**;
  - a branch carrying an **expression-calculation `sort`** (the branch-param re-key does not cover a
    `sort` fragment — forward-compatible fail-closed);
  - when the query runs on the **in-memory** path (any `intersect`/`except`, or any per-branch paging):
    an **expression-calculation outer `sort`** or a **lazy outer filter `:expression`** (both are
    honored on the native path — the in-memory runtime sort/fold path cannot evaluate them);
  - a **mid-chain `:base`** branch (only the first branch may be `:base`);
  - **loading an aggregate or a calculation ON a combination read** (Ash runs `add_aggregates`/
    `add_calculations` on the combined query; both are out of scope this slice).
- **Documented Ash-core limitation — aggregating a combination directly is silently wrong.** A
  standalone `Ash.count`/`Ash.sum`/`Ash.aggregate` over a combination query drops the combination
  in **Ash core** (the aggregate action rebuilds the query without `combination_of`) and returns
  the **un-combined base** result. This is not fixable in the data layer (the combination never
  arrives). To aggregate a combination, **read it and fold app-side.**

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
  **Multi-row bulk upsert IS supported** (Slice 9 Plan 2) — a bulk `upsert? true`
  action (`upsert_fields` required) compiles to ONE `UNWIND … MERGE … ON CREATE …
  ON MATCH …` statement; existing rows update, new rows create, idempotent. The
  `:attribute` discriminator rides the MERGE identity (same-PK cross-tenant upsert
  creates its own row, never hijacks); atomic changes fold on both branches.

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
