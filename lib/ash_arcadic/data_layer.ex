defmodule AshArcadic.DataLayer do
  @moduledoc """
  Ash `DataLayer` for ArcadeDB — the "ash_postgres of ArcadeDB". Executes through
  the tenant-blind `arcadic` transport. Exposes an `arcade do … end` resource
  section and implements the `Ash.DataLayer` behaviour.

      use Ash.Resource, data_layer: AshArcadic.DataLayer

      arcade do
        client MyApp.ArcadicClient   # module implementing AshArcadic.Client
        label :Person                # defaults to the short module name
        skip [:computed]
        sensitive [:ssn]             # binary-storage-typed or skipped
        # database "my_db"           # per-resource default (non-:context)
        # tenant_database {MyApp.Tenancy, :db_for, []}  # :context override
      end

  Capabilities light up across the build: this foundation advertises
  `:multitenancy`; CRUD/query/upsert/transact/traversal land in later plans.
  """

  alias AshArcadic.DataLayer.Info

  @arcade %Spark.Dsl.Section{
    name: :arcade,
    describe: "Configuration for the ArcadeDB data layer.",
    schema: [
      client: [
        type: :atom,
        required: true,
        doc: "Module implementing `AshArcadic.Client` (supplies the `Arcadic.Conn`)."
      ],
      database: [
        type: :string,
        doc:
          "Per-resource default database. Defaults to the client conn's database. Ignored for `:context`."
      ],
      label: [
        type: {:or, [:atom, :string]},
        doc: "Vertex label. Defaults to the resource's short module name."
      ],
      skip: [
        type: {:list, :atom},
        default: [],
        doc: "Attribute names excluded from ArcadeDB properties."
      ],
      sensitive: [
        type: {:list, :atom},
        default: [],
        doc:
          "Attribute names classified as sensitive. Verifier (ValidateSensitive): each must be " <>
            "binary-storage-typed (app-side-encrypted bytes) or listed in `skip`. The verifier " <>
            "checks the type SHAPE — encrypting is the host app's job."
      ],
      tenant_database: [
        type: :mfa,
        doc:
          "MFA applied as `apply(m, f, [tenant | a])` returning the ArcadeDB database name for a " <>
            "`:context` tenant. Defaults to a built-in collision-free encoder."
      ]
    ]
  }

  @behaviour Ash.DataLayer

  use Spark.Dsl.Extension,
    sections: [@arcade],
    transformers: [AshArcadic.DataLayer.Transformers.EnsureLabelled],
    verifiers: [
      AshArcadic.DataLayer.Verifiers.ValidateLabelFormat,
      AshArcadic.DataLayer.Verifiers.ValidateDatabase,
      AshArcadic.DataLayer.Verifiers.ValidateSensitive,
      AshArcadic.DataLayer.Verifiers.ValidateSkip
    ]

  # === Capability declarations (grow per plan) ===
  # Plan 1 advertises only :multitenancy (required for a :context resource to
  # compile). Read/create/update/destroy/upsert/bulk_create/filter/sort/limit/
  # offset/transact/composite_primary_key/changeset_filter land with their
  # callbacks in Plans 2–4, each flipping its clause ABOVE this catch-all.
  @impl true
  def can?(_, :multitenancy), do: true
  def can?(_, _), do: false

  @impl true
  def resource_to_query(resource, _domain) do
    %AshArcadic.Query{
      resource: resource,
      client: Info.client(resource),
      database: Info.database(resource),
      label: Info.label(resource)
    }
  end
end
