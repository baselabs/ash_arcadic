# Contributing to AshArcadic

Thank you for your interest in contributing to AshArcadic!

## Prerequisites

- **Elixir** 1.15+ and **Erlang/OTP** 26+
- A sibling checkout of [`arcadic`](https://github.com/baselabs/arcadic) at
  `../arcadic` (path dependency during co-development)
- **ArcadeDB** for integration tests: `docker run -p 2480:2480 \
  -e JAVA_OPTS="-Darcadedb.server.rootPassword=…" arcadedata/arcadedb:latest`

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
5. Open a Pull Request against `main`.

## Ash conventions

- This is an Ash **data layer** — a `Spark.Dsl.Extension` implementing the
  `Ash.DataLayer` behaviour. Learn from `ash_postgres`, `ash_sqlite`, and the
  sibling `ash_age`.
- Ship a `usage-rules.md` (agent/consumer usage rules) and generate DSL docs via
  `mix spark.cheat_sheets` once the `arcade` DSL section exists.
- Read `AGENTS.md` before touching multitenancy, sensitive-data, or Cypher
  generation code — its Critical Rules are binding.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
