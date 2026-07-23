# AshArcadic

[![Hex.pm](https://img.shields.io/hexpm/v/ash_arcadic.svg)](https://hex.pm/packages/ash_arcadic)
[![Documentation](https://img.shields.io/badge/hex-docs-8e5ea2.svg)](https://hexdocs.pm/ash_arcadic)
[![License: MIT](https://img.shields.io/hexpm/l/ash_arcadic.svg)](LICENSE)

An [Ash Framework](https://ash-hq.org) `DataLayer` for
[ArcadeDB](https://arcadedb.com) — native OpenCypher over the HTTP command API.

AshArcadic is the "`ash_postgres` of ArcadeDB": define Ash resources backed by an
ArcadeDB graph store, with multitenancy, data-classification, and graph traversal
enforced **Ash-natively**. It executes through the
[`arcadic`](https://github.com/baselabs/arcadic) client (the transport — the
"`postgrex` of ArcadeDB").

> **Status: released.** `v0.2.0` is on Hex — `{:ash_arcadic, "~> 0.2.0"}`. The full
> capabilities roadmap has shipped, plus an optional Postgres→ArcadeDB CDC sink (785 tests
> incl. live-ArcadeDB integration, dialyzer clean). Working rules for contributors are in
> [`AGENTS.md`](https://github.com/baselabs/ash_arcadic/blob/main/AGENTS.md); consumer
> usage rules (the fine print per feature) are in [`usage-rules.md`](usage-rules.md).

## Try it in 5 minutes

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fbaselabs%2Fash_arcadic%2Fblob%2Fmain%2Flivebooks%2Ftour.livemd)

[`livebooks/tour.livemd`](https://github.com/baselabs/ash_arcadic/blob/main/livebooks/tour.livemd)
is a runnable Livebook tour of the whole surface (CRUD → queries → keyset streaming →
concurrent bulk → multitenancy → vector search → graph traversal) against a throwaway
database. Every cell is verified against a live ArcadeDB. Click the badge (needs a running
[Livebook](https://livebook.dev)), or open the file from a local clone.

## What it supports

| Area | Capabilities |
|---|---|
| **CRUD & upserts** | create/read/update/destroy; idempotent `MERGE` upsert (incl. composite PKs); atomic `SET` on create/update/upsert (`{:atomic, …}`) |
| **Bulk writes** | `bulk_create`; multi-row bulk upsert; heterogeneous `update_many`; query-scoped `update_query`/`destroy_query` push-down (one Cypher statement); MVCC conflict retry at two levels — concurrent `Ash.bulk_*` with `transaction: false` converges deterministically |
| **Query push-down** | filters (`==/!=/>/</>=/<=/in/is_nil`, boolean logic, string-match, arithmetic/concat/if expressions), sort (orderable-storage allowlist), limit/offset, `distinct`/`distinct_sort`, combinations (`union`/`union_all`/`intersect`/`except`) |
| **Pagination** | offset + **keyset** (`page: [after:/before: …]`, `Ash.stream!`, `count: true`) — cursor-correct across duplicate sort values, per stored type incl. microsecond temporals |
| **Temporal** | datetime/time comparisons compare temporal-to-temporal (ArcadeDB coerces stored ISO8601 → native; params are wrapped in `datetime()`/`localtime()`) |
| **Aggregates** | query aggregates (`count/sum/avg/min/max/first/list/exists`) + relationship aggregates over graph traversals (post-authz Elixir fold) |
| **Calculations** | expression calculations — loaded (Elixir eval) and in filters/sorts (Cypher push-down), fail-closed on sensitive/non-stored refs |
| **Relationships** | standard attribute-FK rels (`belongs_to`/`has_many`/`has_one`/`many_to_many`); **graph traversal** as a manual relationship (`Traverse`: direction, depth ranges, per-source limit/offset, per-hop tenant scoping + per-hop authorization); first-class edge writes (`create_edge`/`destroy_edge` changes, edge properties) |
| **Vector search** | dense kNN (`vector_index`), sparse/learned-sparse (`sparse_vector_index`), hybrid fusion (dense + sparse + full-text arms) — all fail-closed tenant-scoped via a self-injected candidate set |
| **Multitenancy** | `:attribute` (discriminator column) and `:context` (physical DB per tenant), **fail-closed everywhere** — reads, writes, bulk, traversal, vector, keyset cursors |
| **Data classification** | `sensitive` attributes (encrypted-binary contract, compile-verified); value-free redacted errors — no value, tenant, or byte ever reaches an error/log |
| **Transactions** | session transactions (`Ash.DataLayer.transaction`), lazy session open, rollback-safe |
| **Concurrency** | `:async_engine` — Ash runs independent loads/aggregates concurrently (pool-proven safe) |
| **Observability** | `:telemetry` spans for reads/writes/traversals/vector with value-free metadata |
| **CDC mirror** *(optional)* | Postgres→ArcadeDB **effect-once** replication sink (`AshArcadic.Replicant.*`, on the `replicant` transport): declare a mirror resource, wire a sink + integer-LSN watermark + supervised pipeline; watermark advances in the same `Ash.transaction` as the data (atomic, replay = no-op). Fail-closed by verifier + runtime guard (single-database `:attribute`/none, write-action seam-lock, non-sensitive PK, skip-or-halt on sensitive targets, empty-index) |

Deliberate non-goals: `{:lateral_join}` (Ash bypasses it for manual traversal rels),
window-function inline aggregates, transport concerns (pooling, gRPC — those live in
`arcadic`). Per-feature limitations are documented in
[`usage-rules.md`](usage-rules.md).

## Layering

```
Ash core        multitenancy DSL, policies, the tenant concept
   │
AshArcadic ← HERE   Ash.DataLayer: tenancy, classification, traversal, query compile
   │
arcadic         HTTP Cypher transport, sessions/transactions — tenant-blind
   │
ArcadeDB        native OpenCypher engine (97.8% TCK)
```

Multitenancy lives **here**, not in `arcadic` — exactly as `ash_postgres` (not
`postgrex`) owns schema-based tenancy.

## Installation

Not yet on Hex (0.1.0 imminent). Until then, a path/git dependency:

```elixir
# mix.exs
def deps do
  [
    {:ash, "~> 3.0"},
    {:ash_arcadic, path: "../ash_arcadic"} # or git: ...
  ]
end
```

## Connecting to ArcadeDB

AshArcadic asks the host app for a connection handle through one small behaviour —
the `repo` analog. The host owns the URL, credentials, and database name; the data
layer asks only for the handle (called per operation; `Arcadic.Conn` is pure data,
so this is cheap):

```elixir
defmodule MyApp.ArcadicClient do
  @behaviour AshArcadic.Client

  @impl true
  def conn do
    Arcadic.connect(
      System.fetch_env!("ARCADEDB_URL"),          # e.g. "http://localhost:2480"
      "my_database",
      auth: {"root", System.fetch_env!("ARCADEDB_PASSWORD")}
    )
  end
end
```

Everything `Arcadic.connect/3` supports rides along (multi-host failover, read
consistency levels, Bolt transport…) — see arcadic's docs. For `:context`
multitenancy the database given here is the **base** database; tenant databases are
resolved per call.

## Quick start

```elixir
defmodule MyApp.Doc do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshArcadic.DataLayer

  arcade do
    client MyApp.ArcadicClient
    label :Doc                       # vertex label (defaults to module short name)
    # sensitive [:ssn_cipher]        # classified attrs (must be encrypted binaries)
    # vector_index :embedding, dimensions: 1536, similarity: :cosine
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :title, :string, public?: true
    attribute :score, :integer, public?: true
  end

  multitenancy do
    strategy :attribute             # or :context for a physical DB per tenant
    attribute :org_id
  end

  actions do
    default_accept [:id, :org_id, :title, :score]
    defaults [:create, :update, :destroy]

    read :read do
      primary? true
      pagination keyset?: true, offset?: true, countable: true, required?: false
    end
  end
end
```

```elixir
# Everything is plain Ash:
Ash.create!(MyApp.Doc, %{id: "d1", title: "Hello", score: 10}, tenant: "org1")

MyApp.Doc
|> Ash.Query.filter(score > 5)
|> Ash.Query.sort(score: :desc)
|> Ash.read!(tenant: "org1", page: [limit: 20, count: true])

# Stream a large set with bounded memory (keyset pagination under the hood):
MyApp.Doc |> Ash.Query.sort(score: :asc) |> Ash.stream!(tenant: "org1") |> Enum.take(1_000)

# Concurrent bulk load that converges even under write contention:
Ash.bulk_create!(rows, MyApp.Doc, :create, transaction: false, max_concurrency: 8, tenant: "org1")
```

## Relationship to `ash_age`

`ash_age` (Ash data layer for Apache AGE) is the design reference: its
`multitenancy`, `sensitive`-attribute verifiers, and traversal-as-manual-
relationship patterns port here. **One key divergence:** `ash_age` bans `MERGE`
(an Apache AGE performance bug); AshArcadic **uses** `MERGE` for idempotent
upsert — ArcadeDB's native OpenCypher `MERGE` is verified correct.

## Development

```bash
mix deps.get
mix test                              # unit suite (no server needed)
ARCADIC_TEST_URL=http://localhost:2480 mix test   # + live ArcadeDB integration
mix quality                           # format --check-formatted + credo --strict + dialyzer
```

The integration suite provisions throwaway databases per test module and drops them
on exit; it never touches existing data.

## License

MIT — see [LICENSE](LICENSE).
