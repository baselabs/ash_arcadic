# Telemetry reference

AshArcadic emits standard `:telemetry` events for every data-layer operation.
All span metadata is **value-free**: it describes the shape of the operation
(resource module, strategy, counts, kinds) and never carries a property value,
primary key, tenant identity, or Cypher statement. The allowlist is enforced at
runtime — a code path attempting to attach off-allowlist metadata raises
instead of leaking.

## Span events

Each operation is wrapped in `:telemetry.span/3`, emitting the usual
`[:ash_arcadic, :op, :start | :stop | :exception]` events with the operation's
metadata (measurements per `:telemetry.span` conventions: `:duration` on stop;
`:duration` + `:type` + reason fields on exception).

| Event name (`[:ash_arcadic, …]`) | Operation |
|---|---|
| `:read` | `run_query/2` — flat reads, aggregates fold reads, combination branches |
| `:aggregate` | query aggregates (`count/sum/avg/min/max/first/list/exists`) |
| `:create` | single-record create |
| `:bulk_create` | `bulk_create/3` (incl. multi-row bulk upsert) |
| `:upsert` | single-row `MERGE` upsert (incl. `upsert_condition` flow) |
| `:update` | single-record update (atomics fold in) |
| `:update_query` | query-scoped bulk update push-down (one statement) |
| `:update_many` | heterogeneous per-record bulk update |
| `:destroy` | single-record destroy |
| `:destroy_query` | query-scoped bulk destroy push-down |
| `:transaction` | `transaction/4` body |
| `:create_edge` | `AshArcadic.Changes.CreateEdge` |
| `:destroy_edge` | `AshArcadic.Changes.DestroyEdge` |
| `:traverse` | `AshArcadic.ManualRelationships.Traverse` relationship load |

## Direct events

| Event | Measurements | Metadata |
|---|---|---|
| `[:ash_arcadic, :vector, :candidate_count]` | `count` (tenant-scoped candidate `@rid`s materialized for `:attribute` vector search) | `%{}` |
| `[:ash_arcadic, :replicant, :transaction, :apply]` | `change_count`, `duration` | `slot`, `commit_lsn` |
| `[:ash_arcadic, :replicant, :transaction, :skip]` | `duration` (replay-gate hit) | `slot`, `commit_lsn` |

## Metadata allowlist

Span metadata may only carry these keys (enforced by `AshArcadic.Telemetry`):

`resource` · `multitenancy` · `tenant?` · `internal?` · `stale?` ·
`in_transaction?` · `properties?` · `direction` · `row_count` · `batch_size` ·
`group_count` · `matched` · `destination_count` · `depth` · `result` ·
`kinds` · `aggregate_count` · `calculation_count` · `distinct?` ·
`combination?` · `combination_types` · `combination_strategy` ·
`traversal_aggregate?` · `aggregate_kinds` · `bulk_upsert?` · `vector_search?` ·
`vector_kind`

## Example handler

```elixir
:telemetry.attach_many(
  "my-app-ash-arcadic",
  [
    [:ash_arcadic, :read, :stop],
    [:ash_arcadic, :create, :stop],
    [:ash_arcadic, :upsert, :stop]
  ],
  fn event, measurements, metadata, _config ->
    # metadata.resource / metadata.multitenancy are value-free by contract
    :telemetry.execute(
      [:my_app, :db, :op],
      %{duration: measurements.duration},
      %{op: List.to_string(event), resource: inspect(metadata.resource)}
    )
  end,
  nil
)
```

## Related configuration

- `config :ash_arcadic, :write_conflict_retries, N` — client-side attempts for
  optimistic-lock (`ConcurrentModificationException`) write conflicts. Default
  5; `1` disables the client retry layer (the server-side statement retry via
  arcadic's `retries:` body param still applies).
- `config :ash_arcadic, :max_vector_candidates, N` — the `:attribute` vector
  candidate-set ceiling. Default 10 000; exceeding it fails closed (never
  truncates).
