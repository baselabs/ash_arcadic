# AshArcadic

An [Ash Framework](https://ash-hq.org) `DataLayer` for
[ArcadeDB](https://arcadedb.com) — native OpenCypher over the HTTP command API.

AshArcadic is the "`ash_postgres` of ArcadeDB": define Ash resources backed by an
ArcadeDB graph store, with multitenancy, data-classification, and graph traversal
enforced **Ash-natively**. It executes through the
[`arcadic`](https://github.com/baselabs/arcadic) client (the transport — the
"`postgrex` of ArcadeDB").

> **Status: scaffold.** No data-layer implementation yet. Working rules are in
> [`AGENTS.md`](AGENTS.md) — read it first. A fuller project charter (architecture,
> scope, and the open Stage-0 decision — ArcadeDB's physical multitenancy
> primitive) is kept as a local, **unpublished** working doc at `docs/CHARTER.md`.

## Layering

```
Ash core        multitenancy DSL, policies, the tenant concept
   │
AshArcadic ← HERE   Ash.DataLayer: set_tenant/3, sensitive verifiers, traversal
   │
arcadic         HTTP Cypher transport, sessions/transactions — tenant-blind
   │
ArcadeDB        native OpenCypher engine (97.8% TCK)
```

Multitenancy lives **here**, not in `arcadic` — exactly as `ash_postgres` (not
`postgrex`) owns schema-based tenancy. This split is verified against the
`Ash.DataLayer` contract (`set_tenant/3`, the `:multitenancy` feature) and the
sibling `ash_age` data layer.

## Relationship to `ash_age`

`ash_age` (Ash data layer for Apache AGE) is the design reference: its
`multitenancy`, `sensitive`-attribute verifiers, and traversal-as-manual-
relationship patterns port here. **One key divergence:** `ash_age` bans `MERGE`
(an Apache AGE performance bug); AshArcadic **uses** `MERGE` for idempotent
upsert — ArcadeDB's native OpenCypher `MERGE` is verified correct.

## Installation

Not yet published. During co-development it path-depends on `arcadic`:

```elixir
# mix.exs
{:ash_arcadic, path: "../ash_arcadic"}
# which itself pulls {:arcadic, path: "../arcadic"}
```

## Development

```bash
mix deps.get
mix test
mix quality   # format --check-formatted + credo --strict + dialyzer
```

## License

MIT — see [LICENSE](LICENSE).
