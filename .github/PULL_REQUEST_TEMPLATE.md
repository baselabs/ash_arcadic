## What

One or two paragraphs: what this PR changes and why.

## Verification

How the change was proven — please keep the repo's gates honest:

- [ ] `mix format --check-formatted`
- [ ] `mix credo --strict`
- [ ] `mix compile --warnings-as-errors` (dev **and** `MIX_ENV=test`)
- [ ] `mix test --warnings-as-errors`
- [ ] `mix test --include integration` against a throwaway ArcadeDB
      (set `ARCADIC_TEST_URL`; never point tests at a shared database)
- [ ] `mix dialyzer`
- [ ] New behavior has a test you watched FAIL for the right reason first
      (red-before-green, or a mutation red-proof for an existing contract)

## Docs

- [ ] `CHANGELOG.md` under `[Unreleased]`
- [ ] README / usage-rules / troubleshooting / livebook updated if the
      consumer surface changed
- [ ] Generated DSL docs refreshed (`mix spark.cheat_sheets`) if the DSL moved

## Security posture

If this touches values on the wire, errors, logs, telemetry, or tenancy:
confirm the value-free boundary holds (no property values, PKs, tenant-derived
names, or Cypher in any error/log/telemetry surface) — see AGENTS.md Critical
Rules.
