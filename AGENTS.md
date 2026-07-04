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

## Architecture (once built)

A `Spark.Dsl.Extension` implementing the `Ash.DataLayer` behaviour, exposing an
`arcade do ... end` resource section. Learn the shape from `ash_postgres`,
`ash_sqlite`, and — closest — the sibling `ash_age` (`../ash_age`), whose
`data_layer.ex`, `multitenancy.ex`, `validate_sensitive.ex`, and
`manual_relationships/traverse.ex` are the templates to port.

## Critical rules

**1. Parameters only; validate identifiers.** Every value reaches ArcadeDB as a
bound `$param` (via `arcadic`); labels/db-names are allowlist-validated. Never
interpolate into Cypher. This is what makes tenant/classification enforcement
injection-safe.

**2. Multitenancy is fail-closed.** A nil/blank tenant on a multitenant resource
must fail closed (no query runs), never silently span tenants. Port `ash_age`'s
posture: `:context` resolves a per-tenant namespace; `:attribute` scopes **every
node on a path**, including in traversal.

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
DSL docs with `mix spark.cheat_sheets --extensions AshArcadic.DataLayer`.

## Development workflow

```bash
mix deps.get          # pulls ../arcadic via path dep
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
mix dialyzer
# or: mix quality
```

All gates pass before commit/PR. Update `CHANGELOG.md` under `[Unreleased]`.

## Testing

- **Unit** (`test/*_test.exs`): DSL/verifier/compilation tests, no server.
- **Integration** (`test/integration/**`, `@moduletag :integration`): require a
  live ArcadeDB; gate on `ARCADIC_TEST_URL`, skip when unset. ArcadeDB may not
  tolerate concurrent transactions on one connection — default integration tests
  to `async: false` until proven otherwise.
- **TDD:** test first (the `ash_age` convention).

## Docs & lifecycle-artifact policy

- **Tracked / published:** `AGENTS.md`, `README.md`, `CHANGELOG.md`,
  `CONTRIBUTING.md`, `usage-rules.md`, `LICENSE`, and `documentation/` (published
  guides + generated DSL cheat sheets).
- **Never tracked:** the project charter (`docs/CHARTER.md`) plus brainstorm
  specs, plans, exec notes, reviews, and handoffs — under `/docs/`, which is
  **gitignored** (the `ash_age` convention). Keep them there.

## Next action

`/brainstorm-autopilot` **opening with the Stage-0 physical-multitenancy
decision** (CHARTER "OPEN"), then plan, then implement TDD against `ash_age`'s
design and `arcadic`'s transport.
