# Contributing to AshArcadic

Thank you for your interest in contributing to AshArcadic!

## Prerequisites

- **Elixir** 1.18+ and **Erlang/OTP** 27+ (deps resolve from hex, including
  [`arcadic`](https://github.com/baselabs/arcadic)). `.tool-versions` lists the exact builds
  CI runs: the first is the default, the rest are compatibility lanes.
- **ArcadeDB** for integration tests, at the version CI pins: `docker run -p 2480:2480 \
  -e JAVA_OPTS="-Darcadedb.server.rootPassword=…" arcadedata/arcadedb:26.8.1`

## Getting Started

```bash
git clone https://github.com/baselabs/ash_arcadic.git
cd ash_arcadic
mix deps.get
mix test
```

## Development Workflow

1. Create a feature branch from `main`.
2. Make your changes with clear, descriptive commit messages.
3. Ensure all checks pass before opening a PR:

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
mix dialyzer
```

4. Update `CHANGELOG.md` under `[Unreleased]`.
5. Open a Pull Request against `main`. A maintainer lands an accepted change through
   one CI run on `kci/<full sha>`; `main` moves only when that run's `qualified` job passes.

## Live integration and notebooks

`integration.yml` runs the full suite on every toolchain in `.tool-versions` and every
shipped Livebook on the default toolchain. CI calls it with the digest-pinned ArcadeDB
image in `ci.yml`; `canary.yml` calls it daily and on demand with `arcadedata/arcadedb:latest`.
The qualification verdict requires the entire reusable workflow to succeed.

The Hex package includes `livebooks/`; its notebooks also appear in the docs under
Livebooks. CI discovers notebooks from `mix hex.build --unpack` and fails if none are
shipped or a tracked `.livemd` is missing from the package. Every shipped notebook runs
top to bottom in its own VM, preserving cell bindings and aliases. The runner rewrites
only the setup cell's `:ash_arcadic` dependency to this checkout; other dependencies
(including `replicant`) resolve from Hex.

To run the tour against a live ArcadeDB, set `ARCADEDB_URL` and `ARCADEDB_PASSWORD`, then:

```bash
elixir scripts/run_notebook.exs livebooks/tour.livemd
```

The tour creates and drops its own throwaway database. It needs HTTP only: no extra
server plugins or Postgres service. Its Docker recipe matches CI's pinned image.

## Ash conventions

- This is an Ash **data layer** — a `Spark.Dsl.Extension` implementing the
  `Ash.DataLayer` behaviour. Learn from `ash_postgres`, `ash_sqlite`, and the
  sibling `ash_age`.
- Ship a `usage-rules.md` (agent/consumer usage rules) and generate DSL docs via
  `mix spark.cheat_sheets` once the `arcade` DSL section exists.
- Read `AGENTS.md` before touching multitenancy, sensitive-data, or Cypher
  generation code — its Critical Rules are binding.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you agree to uphold it.

## Versioning & deprecations

The package follows [Semantic Versioning](https://semver.org) (see the
CHANGELOG header). The public surface is: the `arcade do ... end` and
`replicant do ... end` DSL sections, the `AshArcadic.*` public functions and
behaviours (`AshArcadic.Client`, `AshArcadic.ReplicantSink`,
`AshArcadic.ReplicantCheckpoint`), telemetry event names and their
measurements/metadata keys, and the `config :ash_arcadic, ...` keys documented
in usage-rules.md.

Anything that would remove or change the meaning of that surface follows the
deprecation discipline — no silent breaks:

- The old form keeps working and is marked `@deprecated` (doc: the replacement
  and the version that deprecates it) **in a minor release**, with a
  CHANGELOG entry.
- Removal happens no earlier than the **next major release** — a deprecated
  form survives at least one full minor cycle.
- Deprecation warnings must be actionable and value-free (same boundary as
  errors: no interpolated values), and are never introduced in patch releases.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
