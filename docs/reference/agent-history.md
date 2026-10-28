# Agent instruction history

Text moved byte-for-byte out of `AGENTS.md` on October 28, 2026, when the owner ruled that
process is sized to the risk of each change. Historical record only; not binding.

## From AGENTS.md: Development workflow and Testing (superseded)

All gates pass before commit/PR. Update `CHANGELOG.md` under `[Unreleased]`.

- **TDD:** test first (the `ash_age` convention).

## From AGENTS.md (whole section)

## Current status

The data layer is **built and released** — `ash_arcadic` 1.2.0 is on hex (the full
Slice 1–11 surface: the `arcade` DSL, query push-down, CRUD/upserts/atomics, bulk
writes, offset + keyset pagination, aggregates, calculations, relationships +
traversal + edge writes, dense/sparse/hybrid vector search, transactions,
`:async_engine`, telemetry — all fail-closed multitenant), verified against the
ArcadeDB 26.10 line (the 1.2.0 release adapts its temporal-coercion and
openCypher property-value drift; see `CHANGELOG.md` and
`documentation/upgrading.md`). The Stage-0 physical-multitenancy decision was
resolved during the brainstorm. The newest subsystem is the
**`AshArcadic.Replicant.*`** CDC sink (Postgres→ArcadeDB effect-once mirror;
optional, compile-gated on `replicant`; shipped in 0.2.0). For the current surface,
read `usage-rules.md`, `README.md`, and the runnable `livebooks/tour.livemd`.
