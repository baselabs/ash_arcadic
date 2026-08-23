---
name: Bug report
about: Something in ash_arcadic behaves incorrectly
title: ""
labels: bug
assignees: ""
---

**Versions**

* ash_arcadic:
* ash:
* arcadic:
* ArcadeDB server (exact version — `docker run ... ` tag or the `/api/v1/server` output):
* Elixir / OTP:

**What happened**

A clear description of the bug. If a data-layer error was involved, paste the
**full error class and message** — ash_arcadic errors are deliberately
value-free (no values, Cypher, or tenant names), so the structural reason is
the diagnostic.

**What you expected**

**Minimal reproduction**

An `Ash` resource + action call (or a small script) that reproduces it. Note
whether the resource is multitenant (`:context` / `:attribute`), which action
type, and whether it was inside `Ash.transaction`.

**Logs / telemetry**

Relevant `[:ash_arcadic, ...]` telemetry events or log lines — please redact
anything sensitive before pasting.
