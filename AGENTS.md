# AshArcadic — AI Agent & Contributor Guide

How to work effectively in this repo. This file is the *how* and is
self-contained; its Critical Rules are binding. A fuller *what & why* charter is
kept as a local, **unpublished** working doc at `docs/CHARTER.md` (not tracked).

## What this is

An Ash `DataLayer` for ArcadeDB — the "`ash_postgres` of ArcadeDB." It owns the
Ash-native mechanism (multitenancy via `set_tenant/3`, sensitive-attribute
verifiers, Cypher generation, traversal) and executes through the tenant-blind
`arcadic` transport. It does **not** own transport, and does **not** re-implement
Ash core's `multitenancy` DSL / tenant concept. For the current surface, read
`usage-rules.md`, `README.md` and `livebooks/tour.livemd`.

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

Make the change, run the tests that cover it, and commit with named paths. Nobody pushes
`main`. A commit lands through one CI run on `kci/<full sha>`; that workflow's final
`qualified` job is the verdict, and `main` moves to the commit only after `qualified` succeeds.
If it goes red, fix forward in a new commit.

The `arcadedb:latest` canary (`.github/workflows/canary.yml`) runs daily and on demand
against the moving upstream image. It never gates a landing: a red canary is upstream drift
to fix before the next deliberate ArcadeDB pin bump.

CI and the canary only restore caches; `.github/workflows/cache-warmer.yml` is the one writer.
On each push, daily and on demand, and only on the default branch, it builds missing caches:
`deps` and `_build` for each Elixir build, and the dialyzer PLT for the default build. A cache's
path or key changes in the warmer and in every restore step together.

Every workflow runs its steps as `bash -eo pipefail` (`defaults: run: shell: bash`), and every
script a job calls is bash with `set -euo pipefail`, so a failure behind a pipe fails its step.
The one exception is the shared `scripts/toolchain.sh`, which is POSIX `sh`, uses no pipe and
checks each status itself.
A command whose failure must fail the job is never followed by `|| true` and never feeds a check
through `$(...)` inside `echo` or a `for` list: assign it to a variable first.

```bash
mix deps.get          # fetch deps (ash, arcadic, … from hex)
mix format
mix test
```

CI runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`,
`mix audit` (unused locks, Hex retirements, and dependency advisories), `mix dialyzer` and
`mix docs --warnings-as-errors` on the default toolchain, and `mix compile --warnings-as-errors`,
`mix credo --strict` and `mix test --warnings-as-errors --include integration`
against a live, digest-pinned ArcadeDB on every Elixir build (`mix quality` bundles format,
credo and dialyzer). The pinned image is written once, in ci.yml's `integration` job; the
reusable `integration.yml` also runs every notebook shipped in the Hex package, top to
bottom against this checkout and a live server, on the default toolchain. Its notebook list
comes from `mix hex.build --unpack`; a tracked notebook omitted from the package fails CI.
The canary runs both the suite and notebooks against `latest`. The `qualified` job depends
on the reusable workflow, so both must pass. Run the checks that cover your change.
Every job fetches with `mix deps.get --check-locked`, so a `mix.lock` that does not match
`mix.exs` fails CI: commit lock changes with the change that causes them.

`.tool-versions` is the only home for Elixir and Erlang versions: the first of each is the
default every workflow runs on, and each further Elixir build, paired with its Erlang by OTP
major, is a compatibility lane. The lowest lane is the supported floor. Change versions there,
never in a workflow.

- A test that fails on every run is a defect: fix it, or quarantine it with a reason, in the
  change that finds it.
- Update `CHANGELOG.md` under `[Unreleased]` when behavior, a dependency or a contract changes;
  other docs only when a contract changes.

The Hex package includes `livebooks/`, and every notebook there is an ExDoc extra in the
Livebooks group.

## CI/CD and releases

CI/CD, the runners, the build machine and releases belong to the infrastructure owner (infra),
for every BaseLabs product. Its requirements bind this repository: the section "What infra
requires of every product" in `baselabs/docs/ci.md` of the BaseLabs infra repository, read from
that repository's default branch. Re-read it whenever you touch a workflow, a Dockerfile, a
release script or a secret. This file points at it and does not copy it.

- **Your part ends at `main`.** A change lands only through the landing run on `kci/<full sha>`
  (see Workflow). Never release, deploy, publish, tag a version, dispatch a workflow, push an
  image by hand, or handle a release, publish or CI key. When something should go out, send
  infra one message: repository, full commit, what goes out, and anything it needs. A release
  is the version commit with its CHANGELOG entry dated, landed; infra asks the owner,
  dispatches `.github/workflows/publish.yml` and tags `v<version>` on the published commit.
  Qualification and publication use `scripts/release/build_archives.sh` with the Hex version
  in `scripts/release/hex-version` to build, compare and inspect both archives before any key
  is available. Publication has no cache; its isolated `mix run --no-mix-exs` step uploads
  only missing archives for an existing package name, never replaces a version, and holds
  the key only for that upload. A redispatch on the same commit resumes only when existing
  registry bytes match. It refuses existing tags, retired versions and missing changelog
  sections, then reads back both archives and exports `release-assets`. Infra creates the
  GitHub release from those verified archives, checksums and release notes after tagging.
- **You write your own workflow changes; infra reviews them.** Before landing any change to
  `.github/`, a Dockerfile, a release script or anything that touches a secret, send infra the
  branch and head commit and wait for its review. Any CI/CD, runner, build-machine or key
  problem goes to infra, not around it.
- **Where checks run:** this repository is public, so it never uses a self-hosted runner or
  the build machine, and nothing that compiles or tests runs on a maintainer's workstation.
  Its checks run on GitHub-hosted runners: push the branch as `kci/<topic>` (ci.yml starts on
  `kci/**`), read that run, fix forward, and delete `kci/<topic>` once the change has landed.
  A secret never appears on a command line, in a log or in a message; if you see one exposed,
  tell infra where it sits without copying the value. Never list process arguments (no `ps`
  with `args` or `-f`, no `/proc/*/cmdline`).
- **Messages to infra:** one per result, complete enough to act on without a reply. No
  acknowledgements and no status notes.
- Every brief given to a sub-agent carries these same rules.

## Testing

- **Unit** (`test/*_test.exs`): DSL/verifier/compilation tests, no server.
- **Integration** (`test/integration/**`, `@moduletag :integration`): require a
  live ArcadeDB; gate on `ARCADIC_TEST_URL`, skip when unset. ArcadeDB may not
  tolerate concurrent transactions on one connection — default integration tests
  to `async: false` until proven otherwise. CI starts a disposable, digest-pinned
  server for each run. To run them yourself, start your own server, set
  `ARCADIC_TEST_URL` and `ARCADIC_TEST_PASSWORD` for it, then run
  `mix test --include integration`.

- **Notebooks** (`livebooks/**/*.livemd`): run each in its own VM with
  `elixir scripts/run_notebook.exs livebooks/tour.livemd`. The runner preserves cell bindings
  and aliases, rewrites only `:ash_arcadic` to this checkout, and leaves other deps on Hex.
  Set `ARCADEDB_URL` and `ARCADEDB_PASSWORD` for a live ArcadeDB; the tour creates and drops
  its own throwaway database and needs no Postgres or extra server plugins.

## Docs & lifecycle-artifact policy

- **Tracked / published:** `AGENTS.md` (there is no `CLAUDE.md`),
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
