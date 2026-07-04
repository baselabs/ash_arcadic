defmodule AshArcadic.DataLayer do
  @moduledoc """
  Ash `DataLayer` for ArcadeDB. **Scaffold placeholder — not yet implemented.**

  When built, this module will be a `Spark.Dsl.Extension` that also implements the
  `Ash.DataLayer` behaviour, exposing an `arcade do ... end` resource section
  (analogous to `ash_age`'s `age do ... end`) with, at minimum:

    * `database` / `client` — which ArcadeDB database + `arcadic` connection.
    * `label` — the vertex/edge type for the resource.
    * `sensitive [...]` / `skip [...]` — classification handling (must be
      app-side-encrypted binary, e.g. via AshCloak, before reaching the graph).

  It will implement the data-layer callbacks (`can?/2`, `run_query/2`,
  `create/2`, `update/2`, `destroy/2`, `set_tenant/3`, `transaction/…`),
  compiling filters/sorts/limits into parameterized Cypher and executing them via
  `Arcadic`. Graph traversal will be exposed as an Ash **manual relationship**
  (the `ash_age` `Traverse` pattern), and multitenancy via `set_tenant/3` mapped
  onto ArcadeDB's physical isolation primitive.

  ## Design references

    * `Ash.DataLayer` behaviour (`set_tenant/3`, the `:multitenancy` feature).
    * `ash_age` (`../ash_age`) — the sibling data layer to port design from.
      **Divergence:** `ash_age` bans `MERGE` (an Apache AGE bug); AshArcadic
      **uses** `MERGE` (ArcadeDB-verified). See `docs/CHARTER.md` / `AGENTS.md`.

  Do not implement piecemeal — the surface is designed via
  `/brainstorm-autopilot` (opening with the physical-multitenancy decision),
  then planned, then built TDD.
  """
end
