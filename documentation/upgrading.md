# Upgrading

AshArcadic follows [Semantic Versioning](https://semver.org). A `1.x` release
is a compatibility commitment for the documented surface: the `arcade do … end`
/ `replicant do … end` DSL options, the `AshArcadic.Client` behaviour, the
error structs, the telemetry event names + metadata allowlist, and the config
knobs. Breaking changes, if ever needed, ship as a new major with an entry
here.

## 0.2.x → 1.0.0

No application-code changes are required. The release moves the dependency
floors to the stabilized transports and formalizes what was already shipped:

- **Elixir floor is now `~> 1.18`** (was `~> 1.15`). The ash 3.32 dependency chain
  (crux/reactor → `ex_ast ~> 1.18`) will not build below 1.18 on a fresh resolution.
  CDC hosts additionally need `replicant`'s own floor: Elixir `~> 1.20.3`.
- **`arcadic` floor is now `~> 1.0`** (was `~> 0.7.1`). The 1.0 transport is
  API-compatible with the surface AshArcadic uses — the full integration suite
  passes unchanged against it. If your own code calls `arcadic` directly,
  review [arcadic's changelog](https://github.com/baselabs/arcadic/blob/main/CHANGELOG.md).
- **`replicant` floor is now `~> 1.2`** (was `~> 0.3`), still `optional: true`.
  A CDC host that pins `replicant` itself should move to `~> 1.2` in lockstep.
  The `AshArcadic.Replicant.*` sink surface (extension options, sink/checkpoint/
  pipeline wiring, effect-once contract) is unchanged.
- The `Arcadic.connect/3` you build in your client module is unchanged; the
  data layer consumes it as-is.

After upgrading, run:

```bash
mix deps.get && mix deps.update ash_arcadic arcadic replicant
```

### Added `replicant` after a non-CDC build?

The CDC subtree compiles only when `replicant` is present, and the compile gate
creates no dependency edge — so an existing build does not automatically
recompile. One-time dance:

```bash
mix deps.get && mix deps.clean ash_arcadic --build && mix compile
```

Until then the missing modules surface as a loud
`AshArcadic.Replicant.Apply … is undefined` — never a silent gap.

## 0.1.x → 0.2.0

0.2.0 was purely additive (the optional CDC sink). No breaking changes;
see [CHANGELOG.md](../CHANGELOG.md).

## Configuration knobs (stable across 1.x)

| Key | Default | Meaning |
|---|---|---|
| `config :ash_arcadic, :write_conflict_retries` | `5` | Client-side attempts for optimistic-lock write conflicts; `1` disables the client retry layer |
| `config :ash_arcadic, :max_vector_candidates` | `10_000` | `:attribute` vector-search candidate-set ceiling (fails closed) |
