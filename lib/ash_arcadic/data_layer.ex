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

  alias Ash.Actions.Helpers.Bulk, as: BulkHelpers
  alias Ash.Error.Changes.StaleRecord
  alias AshArcadic.Cast
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Errors.CreateFailed
  alias AshArcadic.Errors.QueryFailed
  alias AshArcadic.Errors.UpdateFailed
  alias AshArcadic.Query.Filter
  alias AshArcadic.Telemetry
  alias Ecto.Schema.Metadata

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
  # :transact is TRUE — the session-backed transaction callbacks land below.
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
  # Bare `:sort` gates whether Ash pushes ANY sort down (Ash.Query.sort/3 checks it
  # before building the ORDER BY); the `{:sort, storage_type}` clauses below then
  # gate per-field sortability. Both are required — omitting the bare atom makes Ash
  # raise "Data layer does not support sorting" and never reaches the per-type check.
  def can?(_, :sort), do: true
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
  def can?(_, :transact), do: true
  def can?(_, _), do: false

  @impl true
  def resource_to_query(resource, _domain) do
    %AshArcadic.Query{
      resource: resource,
      client: Info.client(resource),
      database: query_database(resource),
      label: Info.label(resource)
    }
  end

  # `database` is IGNORED for :context (spec §6 — the tenant resolves it via
  # set_tenant/3). Seeding the static DSL value would pre-populate query.database
  # and DEFEAT read_conn/2's fail-closed backstop: a :context read that never
  # fired set_tenant (blank tenant) would then read the static database instead of
  # failing closed (a silent unscoped read). nil for :context forces set_tenant to
  # be the sole source of the tenant database.
  defp query_database(resource) do
    case strategy(resource) do
      :context -> nil
      _ -> Info.database(resource)
    end
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

  @impl true
  def run_query(%AshArcadic.Query{} = query, resource) do
    Telemetry.span(:read, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_run_query(query, resource)

      {result,
       %{
         row_count: row_count(result),
         result: Telemetry.result_tag(result),
         tenant?: not is_nil(query.tenant)
       }}
    end)
  end

  defp do_run_query(query, resource) do
    case read_conn(query, resource) do
      {:ok, conn} ->
        {cypher, params} = AshArcadic.Query.to_cypher(query)

        case Arcadic.query(conn, cypher, params) do
          {:ok, rows} ->
            {:ok, decode_records(resource, rows)}

          {:error, error} ->
            {:error,
             QueryFailed.exception(query: "ArcadeDB read query", reason: redact_db_error(error))}
        end

      {:error, reason} ->
        {:error,
         QueryFailed.exception(
           query: "ArcadeDB read query",
           reason: conn_error_reason(reason)
         )}
    end
  end

  # Rows are flat vertex maps (probe: RETURN n → %{"@rid" => .., "@cat" => "v", <props>}).
  # Decode STRICTLY by attribute_map; @rid/@cat/@type and undeclared keys are ignored by
  # Cast.row_to_attrs/3.
  defp decode_records(resource, rows) do
    attribute_map = Info.attribute_map(resource)
    attribute_types = Info.attribute_types(resource)

    Enum.map(rows, fn row ->
      struct(resource, Cast.row_to_attrs(row, attribute_map, attribute_types))
    end)
  end

  defp row_count({:ok, records}), do: length(records)
  defp row_count(_), do: 0

  @impl true
  def create(resource, changeset) do
    Telemetry.span(:create, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_create(resource, changeset)
      {result, %{tenant?: tenant?(changeset), result: Telemetry.result_tag(result)}}
    end)
  end

  defp do_create(resource, changeset) do
    props = changeset_to_properties(resource, changeset)

    case encode_gate(resource, props, CreateFailed) do
      {:error, _} = err -> err
      :ok -> do_create(resource, changeset, props)
    end
  end

  defp do_create(resource, changeset, props) do
    case write_conn(resource, changeset) do
      {:ok, conn} ->
        label = validated_label(resource)

        case Arcadic.command(conn, "CREATE (n:#{label} $props) RETURN n", %{"props" => props}) do
          {:ok, [row]} ->
            {:ok,
             struct(
               resource,
               Cast.row_to_attrs(
                 row,
                 Info.attribute_map(resource),
                 Info.attribute_types(resource)
               )
             )}

          {:ok, rows} ->
            {:error,
             CreateFailed.exception(
               resource: resource,
               reason: "create returned #{length(rows)} rows (expected 1)"
             )}

          {:error, error} ->
            {:error, CreateFailed.exception(resource: resource, reason: redact_db_error(error))}
        end

      {:error, reason} ->
        {:error,
         CreateFailed.exception(
           resource: resource,
           reason: conn_error_reason(reason)
         )}
    end
  end

  @impl true
  def bulk_create(resource, changesets, options) do
    entries =
      Enum.map(changesets, fn changeset ->
        {changeset, changeset_to_properties(resource, changeset)}
      end)

    Telemetry.span(:bulk_create, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_bulk_create(resource, entries, options)

      {result,
       %{
         batch_size: length(entries),
         tenant?: bulk_tenant?(entries),
         result: Telemetry.result_tag(result)
       }}
    end)
  end

  # An empty batch writes nothing (no scoping surface) → :ok without touching the DB.
  defp do_bulk_create(_resource, [], _options), do: :ok

  # Bulk UPSERT is unsupported (native MERGE is single-row; documented non-goal).
  # Ash routes a bulk `upsert? true` action here with `options.upsert? == true`; the
  # normal CREATE path would silently emit `UNWIND ... CREATE` and produce DUPLICATE
  # rows for what the caller asked to be idempotent. Fail CLOSED — reject before any
  # DB touch — rather than fail open against the upsert contract.
  defp do_bulk_create(resource, _entries, %{upsert?: true}) do
    {:error,
     CreateFailed.exception(
       resource: resource,
       reason: "bulk upsert is not supported; use a single-row upsert action"
     )}
  end

  defp do_bulk_create(resource, entries, options) do
    # Fail closed value-free (naming the attribute) if ANY row carries a
    # non-JSON-encodable value — one poisoned row would otherwise raise
    # Jason.EncodeError with the bytes in the message at the wire.
    case first_encode_failure(entries) do
      nil ->
        run_bulk_create(resource, entries, options)

      key ->
        {:error, CreateFailed.exception(resource: resource, reason: encode_error_reason(key))}
    end
  end

  defp run_bulk_create(resource, entries, options) do
    # Ash batches by tenant, so all changesets share one database — resolve off the
    # first, reusing the fail-closed nil-:context-tenant path.
    case bulk_conn(resource, entries) do
      {:ok, conn} ->
        label = validated_label(resource)
        rows = Enum.map(entries, fn {_changeset, props} -> props end)
        return_records? = Map.get(options, :return_records?, false)

        conn
        |> Arcadic.command("UNWIND $rows AS row CREATE (n:#{label}) SET n += row RETURN n", %{
          "rows" => rows
        })
        |> decode_bulk_result(resource, entries, return_records?)

      {:error, reason} ->
        {:error,
         CreateFailed.exception(
           resource: resource,
           reason: conn_error_reason(reason)
         )}
    end
  end

  # `return_records? == false` short-circuits to :ok — Ash discards the rows.
  defp decode_bulk_result({:ok, _result_rows}, _resource, _entries, false), do: :ok

  # CREATE per UNWIND row is 1:1; a mismatch would misalign the record→changeset
  # stamping — fail the batch LOUD, never zip-truncate.
  defp decode_bulk_result({:ok, result_rows}, resource, entries, true)
       when length(result_rows) != length(entries) do
    {:error,
     CreateFailed.exception(
       resource: resource,
       reason:
         "bulk create returned #{length(result_rows)} rows for " <>
           "#{length(entries)} changesets (row-count mismatch)"
     )}
  end

  defp decode_bulk_result({:ok, result_rows}, resource, entries, true) do
    {:ok, decode_bulk_records(resource, entries, result_rows)}
  end

  defp decode_bulk_result({:error, error}, resource, _entries, _return_records?) do
    {:error, CreateFailed.exception(resource: resource, reason: redact_db_error(error))}
  end

  defp bulk_conn(resource, [{changeset, _props} | _]), do: write_conn(resource, changeset)

  defp bulk_tenant?([]), do: false
  defp bulk_tenant?([{changeset, _props} | _]), do: tenant?(changeset)

  # Decodes each returned flat vertex and stamps it with its originating changeset's
  # bulk metadata. Probe: UNWIND preserves input order, so the Nth returned vertex
  # corresponds to the Nth entry; Ash reassembles cross-batch order via
  # `bulk_create_index`.
  defp decode_bulk_records(resource, entries, result_rows) do
    attribute_map = Info.attribute_map(resource)
    attribute_types = Info.attribute_types(resource)

    entries
    |> Enum.zip(result_rows)
    |> Enum.map(fn {{changeset, _props}, row} ->
      record = struct(resource, Cast.row_to_attrs(row, attribute_map, attribute_types))

      %{record | __meta__: %Metadata{state: :loaded, schema: resource}}
      |> BulkHelpers.put_metadata(changeset)
    end)
  end

  @impl true
  def upsert(resource, changeset, keys) do
    Telemetry.span(:upsert, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_upsert(resource, changeset, keys)
      {result, %{tenant?: tenant?(changeset), result: Telemetry.result_tag(result)}}
    end)
  end

  # Native MERGE upsert — the ArcadeDB divergence from the AGE sibling (which BANS
  # MERGE). MATCH on the identity pattern; ON CREATE seeds the full property map, ON
  # MATCH sets only the upsert-fields subset (never re-setting the matched identity).
  # Idempotent by construction: a replay on the same identity matches the SAME @rid.
  defp do_upsert(resource, changeset, keys) do
    identity_keys =
      upsert_identity_keys(resource, keys || Ash.Resource.Info.primary_key(resource))

    if identity_keys == [] do
      # Fail closed: an empty identity would emit `MERGE (n:L {})`, matching ANY node
      # (a catastrophic ON MATCH clobber). Ash structurally guarantees a non-empty PK,
      # but we never rely on an unenforced upstream invariant for a scoping pattern.
      {:error,
       CreateFailed.exception(
         resource: resource,
         reason: "upsert requires a non-empty identity (no primary key or upsert keys)"
       )}
    else
      do_upsert(resource, changeset, keys, identity_keys)
    end
  end

  defp do_upsert(resource, changeset, _keys, identity_keys) do
    props = changeset_to_properties(resource, changeset)
    on_match = upsert_set_map(resource, changeset, identity_keys)

    # Both maps ride the wire ($props for ON CREATE, $on_match for ON MATCH); props
    # already carries the identity values too. Gate them together before any DB touch.
    case encode_gate(resource, Map.merge(props, on_match), CreateFailed) do
      {:error, _} = err -> err
      :ok -> run_upsert(resource, changeset, identity_keys, props, on_match)
    end
  end

  defp run_upsert(resource, changeset, identity_keys, props, on_match) do
    case write_conn(resource, changeset) do
      {:ok, conn} ->
        label = validated_label(resource)
        {match_pattern, match_params} = merge_identity(resource, changeset, identity_keys)

        cypher =
          "MERGE (n:#{label} #{match_pattern}) " <>
            "ON CREATE SET n += $props ON MATCH SET n += $on_match RETURN n"

        params = Map.merge(match_params, %{"props" => props, "on_match" => on_match})

        case Arcadic.command(conn, cypher, params) do
          {:ok, [row]} ->
            {:ok,
             struct(
               resource,
               Cast.row_to_attrs(
                 row,
                 Info.attribute_map(resource),
                 Info.attribute_types(resource)
               )
             )}

          {:ok, rows} ->
            {:error,
             CreateFailed.exception(
               resource: resource,
               reason: "upsert matched #{length(rows)} rows (duplicate identity in graph?)"
             )}

          {:error, error} ->
            {:error, CreateFailed.exception(resource: resource, reason: redact_db_error(error))}
        end

      {:error, reason} ->
        {:error,
         CreateFailed.exception(
           resource: resource,
           reason: conn_error_reason(reason)
         )}
    end
  end

  # Scopes the MERGE identity by the tenant discriminator for `:attribute`
  # resources. MERGE matches on the WHOLE node pattern (there is no WHERE), so a
  # PK-only identity would MATCH a same-PK row belonging to ANOTHER tenant and its
  # ON MATCH SET would mutate/move that row — a cross-tenant hijack (update/destroy
  # avoid this via `changeset_where`; MERGE cannot compose a WHERE). Appending the
  # Ash-force-set discriminator to the identity makes the match tenant-local: a
  # cross-tenant upsert under the same PK no longer matches, so it CREATEs its own
  # row. Fail-closed isolation, AGENTS.md Rule 2. `:context` needs no discriminator
  # (isolation is the physical per-tenant database).
  defp upsert_identity_keys(resource, base_keys) do
    case strategy(resource) do
      :attribute ->
        attr = Ash.Resource.Info.multitenancy_attribute(resource)
        if attr in base_keys, do: base_keys, else: base_keys ++ [attr]

      _ ->
        base_keys
    end
  end

  # Builds the MERGE identity pattern `{k1: $mk_k1, ...}` — each key validated as an
  # identifier (only the field NAME is interpolated), each value serialized + bound to
  # `$mk_<key>` (NEVER interpolated). Composite identities supported.
  defp merge_identity(resource, changeset, identity_keys) do
    types = Info.attribute_types(resource)

    {pairs, params} =
      Enum.reduce(identity_keys, {[], %{}}, fn key, {pairs, params} ->
        field = key |> to_string() |> AshArcadic.Identifier.validate!()

        value =
          Cast.serialize_value(Ash.Changeset.get_attribute(changeset, key), Map.get(types, key))

        param = "mk_#{field}"
        {["#{field}: $#{param}" | pairs], Map.put(params, param, value)}
      end)

    {"{" <> Enum.join(Enum.reverse(pairs), ", ") <> "}", params}
  end

  # The ON MATCH property set — the Ash upsert-fields subset (`set_on_upsert/2`),
  # minus the identity keys (never re-set the match key) and `skip`ped attrs, each
  # value serialized to its wire form.
  defp upsert_set_map(resource, changeset, identity_keys) do
    skip = Info.skip(resource)
    types = Info.attribute_types(resource)

    changeset
    |> Ash.Changeset.set_on_upsert(identity_keys)
    |> Enum.reject(fn {key, _value} -> key in identity_keys or key in skip end)
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key), Cast.serialize_value(value, Map.get(types, key))}
    end)
  end

  @impl true
  def update(resource, changeset) do
    Telemetry.span(:update, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_update(resource, changeset)

      {result,
       %{
         tenant?: tenant?(changeset),
         stale?: stale?(result),
         result: Telemetry.result_tag(result)
       }}
    end)
  end

  defp do_update(resource, changeset) do
    changed = changeset_to_properties(resource, changeset)

    case encode_gate(resource, changed, UpdateFailed) do
      {:error, _} = err -> err
      :ok -> run_update(resource, changeset, changed)
    end
  end

  defp run_update(resource, changeset, changed) do
    case write_conn(resource, changeset) do
      {:ok, conn} ->
        label = validated_label(resource)
        pk = pk_pairs(resource, changeset)
        {where_clause, match_params} = pk_match_clause(pk)
        params0 = Map.put(match_params, "set", changed)

        case changeset_where(changeset, where_clause, params0) do
          {:ok, full_where, params} ->
            cypher = "MATCH (n:#{label}) WHERE #{full_where} SET n += $set RETURN n"

            decode_update_result(
              resource,
              redacted_filter(pk),
              Arcadic.command(conn, cypher, params)
            )

          {:error, _} ->
            {:error,
             UpdateFailed.exception(
               resource: resource,
               reason: "unsupported scoping filter on update"
             )}
        end

      {:error, reason} ->
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason: conn_error_reason(reason)
         )}
    end
  end

  @impl true
  def destroy(resource, changeset) do
    Telemetry.span(:destroy, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_destroy(resource, changeset)

      {result,
       %{
         tenant?: tenant?(changeset),
         stale?: stale?(result),
         result: Telemetry.result_tag(result)
       }}
    end)
  end

  # === Transactions (owner-process-only session; Plan-3 spec §4) ===

  @impl true
  def transaction(resource, fun, _timeout \\ nil, _reason \\ nil) do
    if AshArcadic.Transaction.in_transaction?() do
      # Ash short-circuits nested transactions on in_transaction?/1, so this is only
      # reached if a caller nests directly. JOIN the outer boundary — ArcadeDB has no
      # savepoint contract, so an independent inner rollback is impossible; the outer
      # wrapper owns commit/rollback. A rollback throw from `fun` propagates to it.
      {:ok, fun.()}
    else
      Telemetry.span(:transaction, %{resource: resource}, fn ->
        result = AshArcadic.Transaction.run(fun)
        {result, %{result: transaction_result_tag(result), in_transaction?: true}}
      end)
    end
  end

  @impl true
  def in_transaction?(_resource), do: AshArcadic.Transaction.in_transaction?()

  @impl true
  @spec rollback(Ash.Resource.t(), term()) :: no_return()
  def rollback(_resource, reason), do: AshArcadic.Transaction.rollback_throw(reason)

  # The three span outcomes (spec §6). run/1 returns {:error, :transaction_commit_failed}
  # ONLY on a commit failure; the rollback-throw catch is the only OTHER {:error, _} it
  # returns — so any non-commit-failure error is a rollback. (A reraise does not return
  # here; :telemetry.span emits an :exception event for it instead.)
  defp transaction_result_tag({:ok, _}), do: :commit
  defp transaction_result_tag({:error, :transaction_commit_failed}), do: :error
  defp transaction_result_tag({:error, _}), do: :rollback

  defp do_destroy(resource, changeset) do
    case write_conn(resource, changeset) do
      {:ok, conn} ->
        label = validated_label(resource)
        pk = pk_pairs(resource, changeset)
        {where_clause, match_params} = pk_match_clause(pk)

        case changeset_where(changeset, where_clause, match_params) do
          {:ok, full_where, params} ->
            # RETURN n makes ArcadeDB echo each deleted node ({"n":"<deleted>"}) so
            # a real delete is distinguishable from a no-match — an empty result
            # fails CLOSED as StaleRecord (a scoping-denied delete must not report
            # success). Count only; never row_to_attrs the "<deleted>" shape.
            cypher = "MATCH (n:#{label}) WHERE #{full_where} DETACH DELETE n RETURN n"

            decode_destroy_result(
              resource,
              redacted_filter(pk),
              Arcadic.command(conn, cypher, params)
            )

          {:error, _} ->
            {:error,
             QueryFailed.exception(
               query: "ArcadeDB delete query",
               reason: "unsupported scoping filter on destroy"
             )}
        end

      {:error, reason} ->
        {:error,
         QueryFailed.exception(
           query: "ArcadeDB delete query",
           reason: conn_error_reason(reason)
         )}
    end
  end

  # Count-only decode: {"n":"<deleted>"} is a nested STRING echo, not a vertex map —
  # never Cast.row_to_attrs it. [_|_] means at least one node was deleted → :ok; []
  # means the WHERE matched nothing → fail CLOSED as StaleRecord (an already-gone or
  # scoping-denied delete must NOT report success).
  defp decode_destroy_result(_resource, _filter, {:ok, [_ | _]}), do: :ok

  defp decode_destroy_result(resource, filter, {:ok, []}) do
    {:error, StaleRecord.exception(resource: resource, filter: filter)}
  end

  defp decode_destroy_result(_resource, _filter, {:error, error}) do
    {:error,
     QueryFailed.exception(query: "ArcadeDB delete query", reason: redact_db_error(error))}
  end

  # [{pk_field, serialized_original_value}] — the identity of the row being
  # mutated. get_data/2 (NOT get_attribute/2): a writable PK in `accept` makes
  # get_attribute return the PENDING value, so the WHERE would match zero rows
  # (the stored row still holds the old key) instead of the row being renamed.
  defp pk_pairs(resource, changeset) do
    types = Info.attribute_types(resource)

    resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.map(fn field ->
      value = Ash.Changeset.get_data(changeset, field)
      {field, Cast.serialize_value(value, Map.get(types, field))}
    end)
  end

  # PK WHERE clause + `$match_<key>` params (keys identifier-validated, values
  # parameterized). `$set`/`$paramN` never collide with the `match_` prefix.
  defp pk_match_clause([]) do
    raise ArgumentError, "AshArcadic requires a primary key to match on for update/destroy"
  end

  defp pk_match_clause(pk_pairs) do
    {clauses, params} =
      Enum.reduce(pk_pairs, {[], %{}}, fn {field, value}, {clauses, params} ->
        key = field |> to_string() |> AshArcadic.Identifier.validate!()
        param = "match_#{key}"
        {["n.#{key} = $#{param}" | clauses], Map.put(params, param, value)}
      end)

    {clauses |> Enum.reverse() |> Enum.join(" AND "), params}
  end

  @doc false
  # AND-composes the changeset scoping filter (tenant/policy) onto the PK match,
  # reusing the read Filter translator. Fails CLOSED on an untranslatable filter —
  # never silently drops scoping. `params` pre-seeds Filter's `$paramN` accumulator.
  def changeset_where(changeset, base_where, params) do
    case changeset.filter do
      nil ->
        {:ok, base_where, params}

      filter ->
        case Filter.translate(filter, %AshArcadic.Query{params: params}) do
          {:ok, %AshArcadic.Query{params: params}, ""} ->
            {:ok, base_where, params}

          {:ok, %AshArcadic.Query{params: params}, clause} ->
            {:ok, base_where <> " AND " <> clause, params}

          {:error, _} = err ->
            err
        end
    end
  end

  defp decode_update_result(resource, _filter, {:ok, [row]}) do
    {:ok,
     struct(
       resource,
       Cast.row_to_attrs(row, Info.attribute_map(resource), Info.attribute_types(resource))
     )}
  end

  # ArcadeDB enforces no PK uniqueness → an update WHERE can match 2+ rows. Fail
  # closed value-free; never silently pick one. (Ash update actions default
  # transaction?: true — Plan 3's session rolls the multi-SET back; a
  # transaction? false action keeps it and only surfaces this error.)
  defp decode_update_result(resource, _filter, {:ok, [_, _ | _] = rows}) do
    {:error,
     UpdateFailed.exception(
       resource: resource,
       reason:
         "update matched #{length(rows)} rows for one primary key (duplicate rows in graph?)"
     )}
  end

  defp decode_update_result(resource, filter, {:ok, []}) do
    {:error, StaleRecord.exception(resource: resource, filter: filter)}
  end

  defp decode_update_result(resource, _filter, {:error, error}) do
    {:error, UpdateFailed.exception(resource: resource, reason: redact_db_error(error))}
  end

  # StaleRecord inspects its filter into logs — carry PK field NAMES only (values
  # may be PII/ciphertext, AGENTS.md Rule 4).
  defp redacted_filter(pairs), do: Map.new(pairs, fn {field, _value} -> {field, "<redacted>"} end)

  defp stale?({:error, %StaleRecord{}}), do: true
  defp stale?(_), do: false

  # Maps changeset.attributes (minus `skip`) to a JSON-safe string-keyed property
  # map, each value serialized by attribute type. Passed as ONE `$props` map param
  # (ArcadeDB accepts CREATE (n:L $props) — the AGE per-key-SET divergence). Only the
  # identifier-validated label is interpolated; every VALUE rides `$props` bound.
  defp changeset_to_properties(resource, changeset) do
    skip = Info.skip(resource)
    types = Info.attribute_types(resource)

    changeset.attributes
    |> Enum.reject(fn {key, _value} -> key in skip end)
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key), Cast.serialize_value(value, Map.get(types, key))}
    end)
  end

  # Fail-closed pre-gate for the write surface. serialize_value/2 only base64s
  # TOP-LEVEL binaries; a raw non-UTF8 binary nested inside a `:map`/`:list` value
  # reaches the wire verbatim, where Req's JSON encoder raises `Jason.EncodeError`
  # with the bytes in the message — a value leak (AGENTS.md Rule 4) AND an uncaught
  # crash instead of a value-free {:error, _}. `encode_gate/3` catches it BEFORE any
  # DB touch and returns a value-free error naming only the offending ATTRIBUTE.
  # (Ported from the ash_age sibling's encode_check/first_encode_failure.)
  defp encode_gate(resource, props, error_module) do
    case encode_check(props) do
      :ok ->
        :ok

      {:error, key} ->
        {:error, error_module.exception(resource: resource, reason: encode_error_reason(key))}
    end
  end

  # First property whose serialized value is not JSON-encodable, as `{:error, key}`
  # (the attribute NAME — structural, safe to surface), or `:ok`.
  defp encode_check(props) do
    Enum.find_value(props, :ok, fn {key, value} ->
      case Jason.encode(value) do
        {:ok, _} -> nil
        {:error, _} -> {:error, key}
      end
    end)
  end

  # First offending attribute name across a bulk batch's `{changeset, props}`
  # entries, or nil when every row is encodable.
  defp first_encode_failure(entries) do
    Enum.find_value(entries, fn {_changeset, props} ->
      case encode_check(props) do
        {:error, key} -> key
        :ok -> nil
      end
    end)
  end

  defp encode_error_reason(key) do
    "attribute #{inspect(key)} is not JSON-encodable " <>
      "(raw binary nested in a :map/:list value? encode it app-side, e.g. Base.encode64, " <>
      "or use a :binary-typed attribute)"
  end

  defp validated_label(resource),
    do: resource |> Info.label() |> AshArcadic.Identifier.validate!()

  defp tenant?(changeset), do: not is_nil(Map.get(changeset, :to_tenant))

  @doc false
  # Resolves the ArcadeDB database name for a WRITE. Gated on the multitenancy
  # STRATEGY, not on `to_tenant` presence (which is populated for :attribute too).
  # For :context a nil/blank tenant FAILS CLOSED — there is no global database, and
  # falling through to the base database would be a silent cross-tenant write.
  @spec write_database(Ash.Resource.t(), Ash.Changeset.t()) ::
          {:ok, String.t() | nil} | {:error, :tenant_required}
  def write_database(resource, changeset) do
    if strategy(resource) == :context do
      case Map.get(changeset, :to_tenant) do
        blank when blank in [nil, ""] -> {:error, :tenant_required}
        tenant -> {:ok, AshArcadic.Multitenancy.database_name(resource, tenant)}
      end
    else
      {:ok, Info.database(resource)}
    end
  end

  @doc false
  # The write connection for a changeset, fail-closed on a blank :context tenant. Routes the
  # database-targeted base conn through resolve_conn/2, which is an EXACT passthrough outside
  # a transaction and folds in the cross-database session guard inside one.
  @spec write_conn(Ash.Resource.t(), Ash.Changeset.t()) ::
          {:ok, Arcadic.Conn.t()}
          | {:error, :tenant_required | :cross_database_transaction | :transaction_begin_failed}
  def write_conn(resource, changeset) do
    case write_database(resource, changeset) do
      {:ok, nil} ->
        AshArcadic.Transaction.resolve_conn(conn_for(resource), :write)

      {:ok, database} ->
        AshArcadic.Transaction.resolve_conn(
          Arcadic.with_database(conn_for(resource), database),
          :write
        )

      {:error, :tenant_required} ->
        {:error, :tenant_required}
    end
  end

  @doc false
  # The read connection for a query. :context REQUIRES a database resolved by
  # set_tenant/3; a nil database means set_tenant never fired (blank tenant) → fail
  # closed rather than reading the base database (a silent cross-tenant read). Routes the
  # database-targeted base conn through resolve_conn/2 (exact passthrough outside a tx;
  # session reuse / read-own-conn inside one — a read is never an atomicity hazard).
  @spec read_conn(AshArcadic.Query.t(), Ash.Resource.t()) ::
          {:ok, Arcadic.Conn.t()}
          | {:error, :tenant_required | :cross_database_transaction | :transaction_begin_failed}
  def read_conn(%AshArcadic.Query{} = query, resource) do
    case strategy(resource) do
      :context ->
        case query.database do
          blank when blank in [nil, ""] ->
            {:error, :tenant_required}

          database ->
            AshArcadic.Transaction.resolve_conn(
              Arcadic.with_database(conn_for(resource), database),
              :read
            )
        end

      _ ->
        case query.database do
          nil ->
            AshArcadic.Transaction.resolve_conn(conn_for(resource), :read)

          database ->
            AshArcadic.Transaction.resolve_conn(
              Arcadic.with_database(conn_for(resource), database),
              :read
            )
        end
    end
  end

  defp conn_for(resource), do: Info.client(resource).conn()

  # Maps a value-free conn-resolution error atom to a value-free reason string. The atom is
  # the ONLY thing interpolated — never a database name (tenant-derived), session id, or
  # Cypher (AGENTS.md Rule 4). An unexpected atom raises here (fail-closed loud), never leaks.
  defp conn_error_reason(:tenant_required), do: "multitenancy tenant required for :context write"

  defp conn_error_reason(:cross_database_transaction),
    do: "transaction spans multiple databases (single-database sessions)"

  defp conn_error_reason(:transaction_begin_failed), do: "could not begin ArcadeDB transaction"

  defp strategy(resource), do: Ash.Resource.Info.multitenancy_strategy(resource)

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
