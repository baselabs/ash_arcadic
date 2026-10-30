# AshArcadic — AI Agent & Contributor Guide

How to work effectively in this repo. This file is the *how* and is
self-contained; its Critical Rules are binding. A fuller *what & why* charter is
kept as a local, **unpublished** working doc at `docs/CHARTER.md` (not tracked).

## What this is

An Ash `DataLayer` for ArcadeDB — the "`ash_postgres` of ArcadeDB." It owns the
Ash-native mechanism (multitenancy via `set_tenant/3`, sensitive-attribute
verifiers, Cypher generation, traversal) and executes through the tenant-blind
`arcadic` transport. It does **not** own transport, and does **not** re-implement
Ash core's `multitenancy` DSL / tenant concept.

## Architecture

A `Spark.Dsl.Extension` implementing the `Ash.DataLayer` behaviour, exposing an
`arcade do ... end` resource section. Learn the shape from `ash_postgres`,
`ash_sqlite`, and — closest — the sibling `ash_age` (`../ash_age`), whose
`data_layer.ex`, `multitenancy.ex`, `validate_sensitive.ex`, and
`manual_relationships/traverse.ex` are the templates ported.

An **optional** subsystem, `AshArcadic.Replicant.*` (`lib/ash_arcadic/replicant/`),
adds a Postgres→ArcadeDB **effect-once CDC sink** — a graph resource declares itself a
mirror target with the `AshArcadic.Replicant` extension (`replicant do source_table …
tenant_attribute … end`), and the sink applies decoded `%Replicant.Transaction{}`s from
the sibling `replicant` transport, co-committing an integer-LSN watermark with the
mirrored writes. See `usage-rules.md` for the consumer contract.

## Critical rules

**1. Parameters only; validate identifiers.** Every value reaches ArcadeDB as a
bound `$param` (via `arcadic`); labels/db-names are allowlist-validated. Never
interpolate into Cypher. This is what makes tenant/classification enforcement
injection-safe.

**2. Multitenancy is fail-closed.** A nil/blank tenant on a multitenant resource
must fail closed (no query runs), never silently span tenants. Port `ash_age`'s
posture: `:context` resolves a per-tenant namespace; `:attribute` scopes **every
node on a path**, including in traversal — and, since Slice 2, **every edge** on
the path by default (`scope_edges: false` opts out for out-of-band-edge graphs).

**3. Sensitive = encrypted binary.** Enforce via verifier (port `ash_age`'s R1–R4):
sensitive attrs must be binary-storage-typed (app-side-encrypted, AshCloak) or
`skip`ped; the tenant discriminator is never `sensitive`. The verifier checks the
type shape, not ciphertext — encryption is the host app's job.

**4. Redact at the boundary.** Errors/logs carry structure only (operator + field,
ArcadeDB error class) — never a PK, property value, tenant-derived name, or
Cypher. Redact before Ash inspects a filter into logs.

**5. `MERGE` is used here — unlike the AGE sibling.** ArcadeDB native OpenCypher
`MERGE` is verified: idempotent upsert, `ON CREATE SET` vs `ON MATCH SET` for
stub-vs-rich, `n += $props` for property merge. **Do not** copy `ash_age`'s
"never use MERGE" rule (that is an Apache AGE bug — different engine).

**6. Transport goes through `arcadic` only.** Never open an HTTP call or session
here. If you need a new transport capability, add it to `arcadic` (keeping it
tenant-blind) and consume it.

## The verified ArcadeDB substrate

Lives in `arcadic`'s `AGENTS.md` (the HTTP contract: command endpoint, the
`begin`-needs-no-body gotcha, `arcadedb-session-id` header, `@`-prefixed
result-tag stripping, `MERGE` primitives, readiness 204). Don't duplicate it
here — read it there.

## Ash data-layer callbacks (target surface)

`can?/2` (declare `:multitenancy`, `:transact`, filter/sort/limit capabilities),
`run_query/2`, `create/2`, `update/2`, `destroy/2`, `bulk_create/3`,
`set_tenant/3`, and transaction callbacks — each compiling to parameterized
Cypher run via `Arcadic`. Traversal ships as an Ash manual relationship. Generate
DSL docs with `mix spark.cheat_sheets --extensions AshArcadic.DataLayer,AshArcadic.Replicant`.

## Workflow

Make the change, run the tests that cover it, commit with named paths, and push to `main`.
CI runs once on `main`; if it goes red, fix forward.

```bash
mix deps.get          # fetch deps (ash, arcadic, … from hex)
mix format
mix test
```

CI runs: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`,
`mix hex.audit`, `mix test --include integration` (live ArcadeDB), `mix dialyzer` (`mix quality`
bundles format, credo and dialyzer). Run the ones that cover your change.

- Publishing, deploying and pushes to mirrors always need the owner's approval for that action.
- A test that fails on every run is a defect: fix it, or quarantine it with a reason, in the
  change that finds it.
- Update `CHANGELOG.md` under `[Unreleased]` when behavior, a dependency or a contract changes;
  other docs only when a contract changes.

## Testing

- **Unit** (`test/*_test.exs`): DSL/verifier/compilation tests, no server.
- **Integration** (`test/integration/**`, `@moduletag :integration`): require a
  live ArcadeDB; gate on `ARCADIC_TEST_URL`, skip when unset. ArcadeDB may not
  tolerate concurrent transactions on one connection — default integration tests
  to `async: false` until proven otherwise. When a shared server already runs,
  `ARCADIC_TEST_URL` and `ARCADIC_TEST_PASSWORD` sit in the gitignored `.env`;
  load them with `set -a; . ./.env; set +a`, then `mix test --include integration`.

## Docs & lifecycle-artifact policy

- **Tracked / published:** `AGENTS.md`, `CLAUDE.md` (thin pointer, auto-loaded),
  `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `usage-rules.md`,
  `LICENSE`, `livebooks/`, and `documentation/` (published guides + generated
  DSL cheat sheets).
- **Never tracked:** the project charter (`docs/CHARTER.md`) plus brainstorm
  specs, plans, exec notes, reviews, and handoffs — under `/docs/`, which is
  **gitignored** (the `ash_age` convention). Keep them there.
- **Instruction history:** `docs/reference/agent-history.md` (force-tracked) holds dated
  narratives and superseded instructions moved out of this file; not binding.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook; gitignored).

- For orientation ("where is X handled", "what connects A to B", "explain module M"), prefer `graphify query "<question>"` / `graphify explain "<Module>"` / `graphify path "<A>" "<B>"` over grep/Read fan-outs — one call returns a scoped subgraph with file:line hits.
- Graph output is NAVIGATION, never evidence. Edges reflect the last build, not the working tree, and cross-module call edges can be incomplete (Elixir: file-local only — alias-mediated calls are NOT resolved). Consumer sweeps and every load-bearing claim (review finding, plan anchor) still verify against live code: grep + file:line read.
- After large uncommitted changes, `graphify update .` refreshes the graph (AST-only, no API cost, no key).
