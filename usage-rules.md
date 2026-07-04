# ash_arcadic usage rules

_An Ash DataLayer for ArcadeDB (native OpenCypher over HTTP)._

> Scaffold stage — concrete DSL usage rules land once `AshArcadic.DataLayer` and
> its `arcade do ... end` section exist. The binding facts today:

## What ash_arcadic owns (and what it does not)

- **Owns:** the physical mechanism that makes an ArcadeDB store Ashy —
  `set_tenant/3` / `can?({:multitenancy, …})`, sensitive-attribute verifiers,
  Cypher generation, and traversal as an Ash manual relationship.
- **Does not own:** transport (that is `arcadic`, tenant-blind) or the
  `multitenancy` DSL and tenant concept (that is Ash core, which passes the
  tenant down).

## Non-negotiable rules (inherited design)

- **Parameters only.** Every value reaches ArcadeDB as a bound `$param` via
  `arcadic`; identifiers (labels, db names) are allowlist-validated. No string
  interpolation into Cypher.
- **Sensitive means encrypted-binary.** A `sensitive` attribute must be
  app-side-encrypted binary (e.g. AshCloak) or `skip`ped; the data layer verifies
  the type shape, not the ciphertext. The multitenancy discriminator is never
  `sensitive` (it is a plaintext selector).
- **`MERGE` is used** for idempotent upsert (ArcadeDB-verified) — unlike the
  `ash_age` sibling. Do not import AGE's "never MERGE" rule.

See `docs/CHARTER.md` for architecture and the open multitenancy decision; `AGENTS.md`
for the full working rules.
