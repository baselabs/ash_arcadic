defmodule AshArcadic.Replicant do
  @moduledoc """
  Spark resource extension marking a host `AshArcadic.DataLayer` graph resource
  as a `replicant` CDC mirror target — declares which Postgres `{schema,
  table}` this resource mirrors.

  Add it to a host graph resource:

      use Ash.Resource,
        domain: MyApp.Domain,
        data_layer: AshArcadic.DataLayer,
        extensions: [AshArcadic.Replicant]

      replicant do
        source_table "orders"
        tenant_attribute :org_id
        skip [:internal_notes]
      end

  Diverges from the sibling `ash_replicant`'s `AshReplicant.Resource` (its
  `resource.ex` is the design template — same `%Spark.Dsl.Section{}` +
  `use Spark.Dsl.Extension` idiom) in these deliberate ways:

    * `source_table` is **required, with no reflection fallback** — a graph
      resource's own `arcade do label ... end` is NOT its Postgres source
      table, so the mapping must be declared explicitly.
    * `source_schema` defaults to the static string `"public"` (no reflection).
    * `on_truncate` supports only `:halt` (default, fail-closed) and `:mirror`
      — the precedent's SCD2-only `:close` value is dropped (no SCD2 target-side
      support this slice).
    * Only `source_schema`, `source_table`, `tenant_attribute`, `skip`, and
      `on_truncate` are exposed. `tenant_mfa`, `sensitive`, `upsert_identity`,
      `history_*`, and `on_schema_change` are out of scope — sensitive
      classification is handled target-side by the existing `arcade do
      sensitive ... end` section, not a replicant-section list.
    * `skip` here names **source** (Postgres) columns excluded from the mirror
      write — distinct from `arcade do skip ... end`, which names **target**
      (ArcadeDB) graph attributes.
  """

  @replicant %Spark.Dsl.Section{
    name: :replicant,
    describe:
      "Marks a host graph resource as a `replicant` CDC mirror target and declares its " <>
        "Postgres source mapping and per-resource policies.",
    schema: [
      source_schema: [
        type: :string,
        default: "public",
        doc: "Source Postgres schema name."
      ],
      source_table: [
        type: :string,
        required: true,
        doc:
          "Source Postgres table name. Required — a graph resource's own `arcade` label is " <>
            "not its Postgres source table, so no reflection fallback is offered."
      ],
      tenant_attribute: [
        type: :atom,
        doc:
          "Source column carrying the tenant. Resolved per row and passed as `tenant:` to the " <>
            "mirror action. **Requires the source table to be `REPLICA IDENTITY FULL`**: a " <>
            "`:delete` / PK-changing `:update` resolves the tenant from `old_record`, which is " <>
            "key-only under the default replica identity — the tenant column would be absent, so " <>
            "the apply fails closed `:tenant_required` and halts the whole transaction."
      ],
      skip: [
        type: {:wrap_list, :atom},
        default: [],
        doc:
          "Source **non-identity** columns excluded from the mirror write. Must NOT name the " <>
            "primary key — a dropped PK would forge a fresh vertex identity on every apply, so a " <>
            "skipped PK is rejected at compile by `ValidatePrimaryKeyNotSkipped`."
      ],
      on_truncate: [
        type: {:one_of, [:halt, :mirror]},
        default: :halt,
        doc:
          "Policy for an upstream TRUNCATE: `:halt` (fail-closed, default) or `:mirror` " <>
            "(raw-delete the mirror rows in-txn)."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@replicant],
    verifiers: [
      AshArcadic.Replicant.Verifiers.ValidateSingleDbTenancy,
      AshArcadic.Replicant.Verifiers.ValidateWriteActionsAuthorized,
      AshArcadic.Replicant.Verifiers.ValidatePrimaryKeyNotSensitive,
      AshArcadic.Replicant.Verifiers.ValidatePrimaryKeyNotSkipped
    ]
end
