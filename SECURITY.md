# Security policy

## Reporting a vulnerability

Report vulnerabilities through GitHub's private vulnerability reporting on
[this repo](https://github.com/baselabs/ash_arcadic/security/advisories/new),
or email the maintainer listed on
[hex.pm](https://hex.pm/packages/ash_arcadic). Please do not open a public
issue for a suspected vulnerability. We aim to respond within a week.

## Security posture

AshArcadic is an Ash `DataLayer` for ArcadeDB. Its security model is
**fail-closed by construction** — the guarantees below are enforced in code
(compile-time verifiers + runtime guards), not conventions. The fine print per
feature is in [`usage-rules.md`](usage-rules.md).

### Injection safety — parameters only

Every value reaches ArcadeDB as a bound Cypher `$param` through the `arcadic`
transport; there is no string interpolation of values into Cypher anywhere in
the data layer. Identifiers that DO appear in statement text (labels, database
names, attribute/property names) are validated against a strict allowlist
(`AshArcadic.Identifier`: letter-first, `[A-Za-z0-9_]`, bounded length) before
use, and tenant-derived database names go through the same validation
(`AshArcadic.Multitenancy`).

### Multitenancy is fail-closed

A nil/blank tenant on a multitenant resource never runs a query — reads,
writes, bulk writes, traversal, vector search, and keyset cursors all fail
closed rather than silently spanning tenants. `:attribute` tenancy scopes every
node **and** (by default) every edge on a traversal path; `:context` tenancy
targets a physically distinct database per tenant. Cross-tenant operations are
covered by live mutation tests (an attacker row is fabricated per test, never a
reused victim).

### Sensitive data — encrypted-binary contract

An attribute marked `sensitive` must be binary-storage-typed (app-side-encrypted
ciphertext, e.g. via AshCloak) or excluded from storage (`skip`) — enforced at
compile time. The data layer never sees plaintext: it checks the type shape,
not the ciphertext. The verifier also rejects a `sensitive` multitenancy
discriminator and `sensitive` relationship join keys. Encrypting is the host
app's job; this library enforces that you cannot accidentally store
unencrypted-shape data in a classified column through the data layer.

### Value-free errors, redaction, and telemetry

No error, log line, or telemetry event carries a property value, primary key,
tenant-derived name, or Cypher statement. Database/transport errors pass
through a guard-enforced redaction step (`redact_db_error/1`) that interpolates
only an atom reason under an `is_atom/1` guard — any non-atom reason falls
through to a static string. Telemetry span metadata is allowlist-enforced at
runtime by the data layer's internal telemetry module (hidden from the API docs
by design): an off-allowlist key raises rather than
shipping row-level or tenant-derived data.

### Known limitations (documented, not hidden)

These are the security-relevant edges a host should know about; each is
documented with its mitigation in `usage-rules.md`:

- String-match filters (`contains`, `starts/ends with`) are **case-sensitive**
  in ArcadeDB; a `:ci_string` attribute's case-insensitive semantics are not
  preserved by the pushed-down predicate.
- `is_nil`/`not is_nil` on a `sensitive` field is allowed (a presence oracle:
  the has-value cohort is enumerable). Use a host field policy if
  presence-as-classification matters.
- `:context` tenant database names are operator-visible server-side; a tenant
  space whose identity is itself classified should hash names via
  `tenant_database`.
- Concurrent `MERGE` upserts of the same NEW identity can both create (no
  identity uniqueness enforced by default) — add a unique index or serialize
  writers for a hard guarantee.
- A string function over a relationship path currently raises inside Ash core
  before AshArcadic sees it (upstream bug; documented in usage-rules).
- ArcadeDB HTTP transport is the default; TLS and other transport options are
  the host's `arcadic` connection concern (`Arcadic.connect` transport opts).
- Commands have **no timeout by default** (arcadic default). Set
  `timeout: <ms>` in your client module's `Arcadic.connect/3` to bound every
  data-layer call against a hung server.

### Dependency surface

Runtime deps are `ash`, `spark`, `splode`, `arcadic`, `jason`, `telemetry`
(plus `simple_sat`, a pure-Elixir SAT solver, so policy authorizer never needs
an NIF). The Postgres CDC transport (`replicant`) is `optional: true` — a
non-CDC host compiles without it. CI runs `mix hex.audit` and keeps the
resolved lock advisory-free.

## Scope

This library does not own transport security (TLS, auth, pooling — that is
`arcadic` and your host app), does not encrypt data (host-side, e.g.
AshCloak), and does not provide row-level authorization beyond what Ash
policies + fail-closed tenancy give you. Vulnerabilities in ArcadeDB itself
belong upstream.
