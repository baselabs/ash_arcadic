# Upgrading

AshArcadic follows [Semantic Versioning](https://semver.org). A `1.x` release
is a compatibility commitment for the documented surface: the `arcade do … end`
/ `replicant do … end` DSL options, the `AshArcadic.Client` behaviour, the
error structs, the telemetry event names + metadata allowlist, and the config
knobs. Breaking changes, if ever needed, ship as a new major with an entry
here.

## 1.1.x → 1.2.0

Adapts to the ArcadeDB 26.10 server line (all changes probed live against both
26.8.1 and 26.10.2) and to arcadic 1.2's typed transport errors.

- **`arcadic` floor is now `~> 1.2`.** Unencodable param values now surface as
  the typed, value-free `ArcadeDB error (invalid_params)` class at the wire
  (arcadic 1.1 raised `Jason.EncodeError` with the bytes in the message);
  AshArcadic's pre-wire encode gates still fire first and name the offending
  attribute wherever they cover the path.
- **Temporal comparisons wrap both sides.** ArcadeDB 26.10 stopped coercing
  stored ISO8601 strings to native temporals, which silently inverted the 1.1
  fix's behavior on new servers. Filters and keyset cursors now render
  `datetime(n.at) > datetime($p)` (and `localtime()` for `:time`), correct on
  every supported server version. No action needed from you.
- **`:map` attributes store as canonical JSON strings.** ArcadeDB 26.10
  enforces the openCypher property-value rule (a map-valued property write is
  rejected 400 `InvalidPropertyTypeException`), so `:map` (and
  `{:array, :map}`) values ride the wire as a canonical JSON string — legal on
  every supported server, order-insensitively comparable, and free of the old
  32-level nesting cap. Rows written by ≤1.1 on a ≤26.9 server still read
  back; **equality/`in` filters on `:map` match new-format rows only** —
  re-write legacy rows once if you rely on map equality.
- **Edge writes scope tenancy per endpoint.** An `:attribute`-multitenant
  DESTINATION behind a global (non-multitenant) source is now scoped by its
  own discriminator and requires a tenant (previously such an edge write bound
  the destination by bare PK — a cross-tenant write hole; treat any workload
  that relied on that shape as unintended behavior now correctly rejected).
  Each endpoint's bound value is its own `parse_attribute(to_tenant)`
  serialization, so edge writes against custom-parse resources now MATCH
  stored rows (previously they failed whole under a non-default
  `parse_attribute`).
- **New Replicant compile verifier.** A mirror resource not on the AshArcadic
  data layer now fails at compile instead of halting at sink runtime. (A
  `sensitive` attribute outside `replicant skip` still compiles — a graph-only
  sensitive attribute is valid; the runtime `:sensitive_plaintext` halt covers
  arriving columns.)
- **Snapshot watermark writes are monotonic by construction** (a repeated
  snapshot LSN can never regress the durable checkpoint; a corrupt stored
  watermark self-heals on the next snapshot).

After upgrading, run:

```console
mix deps.get && mix compile
```

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
