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
  alias AshArcadic.Query.Filter

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
      AshArcadic.DataLayer.Verifiers.ValidateSkip,
      AshArcadic.DataLayer.Verifiers.ValidateMultitenancyAttr
    ]

  # === Capability matrix (read + write + query-building) ===
  # :transact stays FALSE — Plan 3 owns the session callbacks and flips it.
  @impl true
  def can?(_, :read), do: true
  def can?(_, :create), do: true
  def can?(_, :update), do: true
  def can?(_, :destroy), do: true
  def can?(_, :upsert), do: true
  def can?(_, :bulk_create), do: true
  def can?(_, :filter), do: true
  def can?(_, :limit), do: true
  def can?(_, :offset), do: true
  def can?(_, :boolean_filter), do: true
  def can?(_, :nested_expressions), do: true
  def can?(_, :multitenancy), do: true
  def can?(_, :composite_primary_key), do: true
  def can?(_, :changeset_filter), do: true
  # Ash asks {:sort, Ash.Type.storage_type(type)}. Binary is base64 (not
  # byte-order-preserving); :decimal is an exact string (lexicographic) — sorting
  # either returns a silently wrong order, so reject → Ash.Error.Query.UnsortableField.
  def can?(_, {:sort, :binary}), do: false
  def can?(_, {:sort, :decimal}), do: false
  def can?(_, {:sort, _}), do: true
  # Ash 3.29 authorizes filters per predicate node via {:filter_expr, <struct>}
  # (deps/ash/lib/ash/filter/filter.ex:3532). {:filter_operator, _} is not a
  # current capability query (absent from the feature() type), so it is omitted.
  def can?(_, {:filter_expr, %Ash.Query.Operator.Eq{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.NotEq{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.In{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.IsNil{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.GreaterThan{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.LessThan{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.GreaterThanOrEqual{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.LessThanOrEqual{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.Contains{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.StringStartsWith{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.StringEndsWith{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.BooleanExpression{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Not{}}), do: true
  def can?(_, {:filter_expr, _}), do: false
  def can?(_, {:lateral_join, _}), do: false
  def can?(_, {:aggregate, _}), do: false
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

  @impl true
  def set_tenant(resource, %AshArcadic.Query{} = query, tenant) do
    # Fires only for :context (Ash guards set_tenant by strategy). database_name/2
    # raises value-free on a nil/blank/too-long/non-String.Chars identifier — a bad
    # tenant NEVER resolves to a base database (fail-closed isolation).
    {:ok,
     %{query | database: AshArcadic.Multitenancy.database_name(resource, tenant), tenant: tenant}}
  end

  @impl true
  def set_context(_resource, %AshArcadic.Query{} = query, context) do
    # Captures the raw query tenant for ALL strategies (Ash sets private.tenant even
    # for :attribute, where set_tenant never fires). Pure annotation — feeds the
    # `tenant?` telemetry tag; no read behavior changes (no RLS to scope).
    {:ok, %{query | tenant: get_in(context, [:private, :tenant])}}
  end

  @impl true
  def filter(query, filter, _resource) do
    # RUNTIME SCOPING PATH — fails CLOSED. An unsupported filter propagates
    # {:error, %UnsupportedFilter{}} to Ash (no query runs; scoping never dropped).
    case Filter.translate(filter, query) do
      {:ok, query, ""} -> {:ok, query}
      {:ok, query, clause} -> {:ok, %{query | filters: query.filters ++ [clause]}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def sort(query, sort, _resource) do
    sort_clauses =
      Enum.map(sort, fn
        {%Ash.Resource.Attribute{name: name}, direction} -> {name, direction}
        {name, direction} when is_atom(name) -> {name, direction}
      end)

    {:ok, %{query | sort: query.sort ++ sort_clauses}}
  end

  @impl true
  def limit(query, limit, _resource), do: {:ok, %{query | limit: limit}}

  @impl true
  def offset(query, offset, _resource), do: {:ok, %{query | offset: offset}}

  @doc false
  # Maps an arcadic error to a value-free structural reason. We interpolate `reason`
  # ONLY under a `when is_atom(reason)` guard — the atom is guard-ENFORCED here, not
  # trusted from the annotation. Both structs annotate `reason :: atom()`, but that is
  # UNENFORCED: arcadic passes the underlying Req/Mint reason through verbatim
  # (../arcadic transport/http.ex:85,153,197,209,239; bolt/connection.ex:20), and
  # Mint's reason type is term() — a tuple/charlist/string reason can reach here and
  # embed a host or value. Any non-atom reason (on EITHER struct) falls through to the
  # static catch-all — fail CLOSED — which NEVER interpolates or inspects the term
  # (String.Chars on a tuple would raise a value-carrying Protocol.UndefinedError; see
  # the redaction-fail-path memory). Callers pass the result as the `reason:` of a
  # Query/Create/UpdateFailed, which `inspect`s it — a structural string stays
  # value-free through that inspect.
  def redact_db_error(%Arcadic.Error{reason: reason}) when is_atom(reason),
    do: "ArcadeDB error (#{reason})"

  def redact_db_error(%Arcadic.TransportError{reason: reason}) when is_atom(reason),
    do: "ArcadeDB transport error (#{reason})"

  def redact_db_error(_other), do: "ArcadeDB error"
end
