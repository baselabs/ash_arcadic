# AshArcadic — start here

**Before any work, read these two files (this repo's context is in them, not here):**

1. **`AGENTS.md`** — the working guide: critical rules (params-only, fail-closed
   multitenancy, sensitive = encrypted-binary, `MERGE`-is-used-here-unlike-AGE),
   the target Ash data-layer callback surface, and the dev/test workflow.
   **Binding.**
2. **`docs/CHARTER.md`** — the project charter: mission, layering, scope, the
   decisions, and **the open Stage-0 decision** (ArcadeDB's physical
   multitenancy primitive) the brainstorm must settle first. A local,
   **unpublished** working doc (gitignored).

## One-line orientation

AshArcadic is the **Ash `DataLayer` for ArcadeDB** — the "`ash_postgres` of
ArcadeDB." It owns multitenancy / classification / traversal and executes through
the sibling **`arcadic`** transport client. No data-layer code exists yet.

## Cross-repo context (needed for the brainstorm)

This repo is not self-contained. Design work reads two sibling checkouts by path:

- **`../ash_age`** — the sibling Ash data layer (for Apache AGE) whose
  `multitenancy.ex`, `validate_sensitive.ex`, `manual_relationships/traverse.ex`,
  and `data_layer.ex` are the design to port. **Mind the `MERGE` divergence.**
- **`../arcadic`** — the transport; see its `AGENTS.md` for the verified ArcadeDB
  HTTP contract.

Run brainstorm/plan/implement sessions from a checkout where both siblings exist.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook; gitignored).

- For orientation ("where is X handled", "what connects A to B", "explain module M"), prefer `graphify query "<question>"` / `graphify explain "<Module>"` / `graphify path "<A>" "<B>"` over grep/Read fan-outs — one call returns a scoped subgraph with file:line hits.
- Graph output is NAVIGATION, never evidence. Edges reflect the last build, not the working tree, and cross-module call edges can be incomplete (Elixir: file-local only — alias-mediated calls are NOT resolved). Consumer sweeps and every load-bearing claim (review finding, plan anchor) still verify against live code: grep + file:line read.
- After large uncommitted changes, `graphify update .` refreshes the graph (AST-only, no API cost, no key).
