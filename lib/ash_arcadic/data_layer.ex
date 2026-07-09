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
  alias AshArcadic.Errors.UnsupportedFilter
  alias AshArcadic.Errors.UpdateFailed
  alias AshArcadic.Query.Expression
  alias AshArcadic.Query.Filter
  alias AshArcadic.Telemetry
  alias Ecto.Schema.Metadata

  @edge_entity %Spark.Dsl.Entity{
    name: :edge,
    describe: "Defines an edge mapping from this vertex to a destination resource.",
    args: [:name],
    target: AshArcadic.Edge,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "Edge name (referenced by CreateEdge/DestroyEdge `edge:`)."
      ],
      label: [
        type: :atom,
        required: true,
        doc: "Edge label in the graph (a valid Arcadic.Identifier)."
      ],
      direction: [
        type: {:one_of, [:outgoing, :incoming, :both]},
        default: :outgoing,
        doc: "Edge direction."
      ],
      destination: [
        type: :atom,
        required: true,
        doc: "Destination resource module (single-attribute PK)."
      ],
      properties: [
        type: {:list, :atom},
        default: [],
        doc: "Edge property keys, set from same-named declared action arguments."
      ],
      multiple?: [
        type: :boolean,
        default: false,
        doc:
          "false → idempotent MERGE (one edge per endpoint-pair+label); true → CREATE (parallel edges)."
      ]
    ]
  }

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
    ],
    entities: [@edge_entity]
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
      AshArcadic.DataLayer.Verifiers.ValidateMultitenancyAttr,
      AshArcadic.DataLayer.Verifiers.ValidateEdge,
      AshArcadic.DataLayer.Verifiers.ValidateRelationshipFk
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

  # Slice 7: value-expression operators/functions the Query.Expression translator emits — advertised
  # so a comparison over an arithmetic/concat/if/calc-expanded expression HYDRATES (else Ash refuses
  # the predicate upstream and it never reaches Filter.translate). Contains/StringStartsWith/
  # StringEndsWith are already advertised above.
  def can?(_, {:filter_expr, %Ash.Query.Operator.Basic.Plus{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.Basic.Minus{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.Basic.Times{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.Basic.Div{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.Basic.Concat{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.If{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.IsNil{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.StringDowncase{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.StringLength{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.Length{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.StringTrim{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.Round{}}), do: true
  def can?(_, {:filter_expr, _}), do: false
  # Query aggregates (Slice 3) — Ash.count/sum/aggregate route to run_aggregate_query/3,
  # gated per kind here. {:aggregate,_} (inline field loading) and {:aggregate_relationship,_}
  # (relationship-spanning) stay false (§12): a manual traversal can't be pushed into an
  # aggregate query, and ArcadeDB has no window functions for inline loading.
  def can?(_, {:query_aggregate, :count}), do: true
  def can?(_, {:query_aggregate, :sum}), do: true
  def can?(_, {:query_aggregate, :avg}), do: true
  def can?(_, {:query_aggregate, :min}), do: true
  def can?(_, {:query_aggregate, :max}), do: true
  def can?(_, {:query_aggregate, :first}), do: true
  def can?(_, {:query_aggregate, :list}), do: true
  def can?(_, {:query_aggregate, :exists}), do: true
  def can?(_, {:query_aggregate, _}), do: false
  def can?(_, {:lateral_join, _}), do: false
  # Slice 4: relationship aggregates over a manual Traverse rel, computed post-authz in Elixir.
  # {:aggregate_relationship, rel} is a COMPILE gate (verifier) — true for every manual rel.
  # {:aggregate, kind}=true enables the inline add_aggregate/run_query path; {:aggregate,:unrelated}
  # STAYS false so Ash refuses flat inline aggregates upstream (add_aggregate only gets rel aggs).
  def can?(_, {:aggregate_relationship, _}), do: true
  def can?(_, {:aggregate, :unrelated}), do: false
  def can?(_, {:aggregate, :custom}), do: false

  def can?(_, {:aggregate, kind})
      when kind in [:count, :sum, :avg, :min, :max, :first, :list, :exists],
      do: true

  def can?(_, {:aggregate, _}), do: false
  def can?(_, :transact), do: true
  def can?(_, :traverse), do: true
  # Slice 5: standard (attribute-FK) relationships. {:filter_relationship, rel} is Ash's gate for
  # filtering a SOURCE on a related field (filter.ex:3599). True for STANDARD rels — has_many/has_one
  # carry manual: nil; belongs_to/many_to_many have NO :manual field (Map.get → nil) — so Ash routes
  # the filter through a separate destination read + source-IN rewrite ({:join} stays false). A MANUAL
  # Traverse rel carries manual: {mod, opts} → false: a clean "not filterable" reject, NOT an IN-rewrite
  # over the traversal destination WITHOUT per-hop authz (V1). Loading + aggregates already work via
  # Ash's core batched-IN loader over run_query — no new callback.
  def can?(_, {:filter_relationship, rel}) do
    # Slice 5 (fail-closed, amended): standard rels are filterable, EXCEPT when the destination
    # carries ANY authorizer. Ash routes a source-on-related filter through the separate-read
    # IN-rewrite, which reads the destination with authorize?: false (deps/ash filter.ex:2091,2104) —
    # that flag disables the WHOLE authz pipeline (every authorizer, not just Ash.Policy.Authorizer),
    # bypassing the destination's ROW policy and ORACLING field-policy-protected values. can? is
    # actor-agnostic and cannot apply the policy, so it fails closed at parse (check_filterable,
    # filter.ex:3599). Loading + aggregate folds do NOT use {:filter_relationship} — unaffected.
    # Manual Traverse rels stay false (V1). Use Map.get (bare-map unit asserts have no :destination).
    is_nil(Map.get(rel, :manual)) and not destination_has_authorizer?(Map.get(rel, :destination))
  end

  # Slice 7: expression calculations. Advertising this routes EVERY has_expression? calc through
  # add_calculations/3 (regardless of per-operator {:filter_expr} capability) — that callback is the
  # ref-classification fail-closed gate (sensitive/non-stored → reject BEFORE the query runs), and
  # supported calcs compute in run_query via Elixir eval over the flat RETURN n (NOT Cypher).
  def can?(_, :expression_calculation), do: true

  # Forward-compat only: in Ash 3.29.3 `:expression_calculation_sort` is never checked in the
  # action/query pipeline — the real gate that lets a calc-sort survive hydrate_calculations is
  # `:expression_calculation` (above). Advertised so the capability reads honestly; not the gate.
  def can?(_, :expression_calculation_sort), do: true

  def can?(_, _), do: false

  # Slice 5 (fail-closed): true when the filter destination carries ANY authorizer. Used by
  # can?({:filter_relationship, rel}) to reject a source-on-related filter to an authorizer-bearing
  # dest — the separate-read IN-rewrite reads it authorize?:false, which bypasses ALL authz (not just
  # Ash.Policy.Authorizer) → row-policy bypass + field-policy oracle. A custom (non-Ash.Policy)
  # authorizer is equally bypassed, so reject on a NON-EMPTY authorizer list, never on a specific one.
  # is_atom guard: the bare-map unit asserts pass no :destination key (Map.get → nil → false).
  defp destination_has_authorizer?(dest) when is_atom(dest) and not is_nil(dest) do
    Ash.Resource.Info.authorizers(dest) != []
  end

  defp destination_has_authorizer?(_), do: false

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
    # `internal?` distinguishes a nested relationship-filter read (Ash sets
    # private.internal? for the separate-read IN path) from a top-level read — a
    # value-free telemetry tag consumed by the run_query :read span.
    {:ok,
     %{
       query
       | tenant: get_in(context, [:private, :tenant]),
         internal?: get_in(context, [:private, :internal?]) == true
     }}
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
  # SORT SCOPING PATH — fails CLOSED. A field sort that is not a STORED attribute (a `skip`-ped
  # attribute) is rejected value-free rather than emitted as `ORDER BY n.<field>` against a
  # non-existent property (ArcadeDB → null → silent arbitrary order). An INLINED expression-calc
  # sort (Ash passes %Ash.Query.Calculation{opts: [expr: …]}) translates via Expression into an
  # ORDER-BY fragment, threading its params onto the query; a sensitive/non-stored ref (or an
  # unsupported op) inside fails closed value-free. Same stored guard as the aggregate `:first`
  # sort path (Info.stored_field?/2).
  def sort(query, sort, resource) do
    Enum.reduce_while(sort, {:ok, query}, fn entry, {:ok, q} ->
      case sort_clause(entry, resource, q) do
        {:ok, q2, clause} -> {:cont, {:ok, %{q2 | sort: q2.sort ++ [clause]}}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # An inlined expression-calc sort → translate its expression to a Cypher ORDER-BY fragment
  # (params threaded onto the query). A sensitive/non-stored ref, or an unsupported op, inside →
  # Expression fails closed value-free. A calc without an :expr key (a module calc) → reject.
  defp sort_clause({%Ash.Query.Calculation{opts: opts}, direction}, _resource, query) do
    case Keyword.fetch(opts, :expr) do
      {:ok, expr} ->
        case Expression.translate(expr, query) do
          {:ok, q, cypher} -> {:ok, q, {:expr, cypher, direction}}
          {:error, _} -> {:error, sort_error("sort over an unsupported calculation expression")}
        end

      :error ->
        {:error, sort_error("sort over an expression/calculation field is unsupported")}
    end
  end

  # A field sort entry (atom or resolved %Ash.Resource.Attribute{}) → guard on stored; any other
  # calculation/aggregate STRUCT field → :expression reject value-free.
  defp sort_clause(entry, resource, query) do
    case normalize_sort_entry(entry) do
      {name, direction} ->
        if Info.stored_field?(resource, name),
          do: {:ok, query, {name, direction}},
          else: {:error, sort_error("sort field #{name} is not a stored attribute")}

      :expression ->
        {:error, sort_error("sort over an expression/calculation field is unsupported")}
    end
  end

  # {name, direction} for a stored-attribute sort entry (atom or the resolved
  # %Ash.Resource.Attribute{} form Ash passes); :expression for a calculation/aggregate
  # STRUCT field (non-atom) — not a Cypher-expressible property, rejected value-free.
  defp normalize_sort_entry({%Ash.Resource.Attribute{name: name}, direction}),
    do: {name, direction}

  defp normalize_sort_entry({name, direction}) when is_atom(name), do: {name, direction}
  defp normalize_sort_entry(_entry), do: :expression

  # Value-free: `reason` names only the field atom / a static string — never a value (Rule 4).
  defp sort_error(reason), do: QueryFailed.exception(query: "ArcadeDB sort", reason: reason)

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
         tenant?: not is_nil(query.tenant),
         internal?: query.internal?,
         in_transaction?: AshArcadic.Transaction.in_transaction?(),
         traversal_aggregate?: query.aggregates != [],
         aggregate_kinds: Enum.map(query.aggregates, & &1.kind),
         aggregate_count: length(query.aggregates),
         calculation_count: length(query.calculations)
       }}
    end)
  end

  defp do_run_query(%AshArcadic.Query{aggregates: aggs} = query, resource) do
    case read_conn(query, resource) do
      {:ok, conn} ->
        {cypher, params} = AshArcadic.Query.to_cypher(query)

        case Arcadic.query(conn, cypher, params) do
          {:ok, rows} ->
            records = decode_records(resource, rows)
            attach_computed(records, aggs, query.calculations, resource)

          {:error, error} ->
            {:error,
             QueryFailed.exception(query: "ArcadeDB read query", reason: redact_db_error(error))}
        end

      # read_conn only ever yields :tenant_required here: resolve_conn/2 in :read mode never
      # returns a transaction error (a cross-database read runs on its own conn; reads never
      # open a session). Keep the read-accurate message rather than the write-oriented
      # conn_error_reason/1 (a :context read that mislabels itself "write" is a regression).
      {:error, :tenant_required} ->
        {:error,
         QueryFailed.exception(
           query: "ArcadeDB read query",
           reason: "multitenancy tenant required for :context read"
         )}
    end
  end

  # No stashed aggregates → records unchanged (Slice-1/2/3 parity).
  defp attach_traversal_aggregates(records, [], _resource), do: {:ok, records}

  defp attach_traversal_aggregates(records, aggs, resource) do
    # Each aggregate: one batched authorized Ash.load over ALL records at once (Traverse UNWIND $ids
    # → not N+1), then fold + attach per record. Multi-segment paths fail closed value-free (non-goal).
    # NOTE: add_aggregate/3 PREPENDS, so `aggs` is in reverse declaration order — harmless here because
    # each aggregate is loaded+folded+attached INDEPENDENTLY by its own .load/.name key (no positional
    # zipping against anything). (Aggregates sharing a rel+query could share one load — future opt.)
    # `resource` is the SOURCE; the DESTINATION type map is resolved per-aggregate in load_and_attach
    # (different aggregates may target different rels/destinations).
    Enum.reduce_while(aggs, {:ok, records}, fn agg, {:ok, recs} ->
      case load_and_attach(recs, agg, resource) do
        {:ok, recs2} -> {:cont, {:ok, recs2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_and_attach(records, %Ash.Query.Aggregate{relationship_path: [rel]} = agg, source) do
    # The fold runs over DESTINATION records (Traverse Read B). guard_field/2's binary/sensitive
    # rejection and the min/max comparator key off the DESTINATION field's storage type — resolve the
    # type map from the destination resource, NOT `source` (self-referential coincides; a cross-resource
    # traverse would otherwise mis-type or omit the dest field → wrong comparator / sensitive-guard
    # bypass). Matches Traverse.do_load's own Info.attribute_types(dest) for the dest PK.
    types = aggregate_dest_types(source, agg)
    ctx = agg.context || %{}

    load_opts = [
      actor: Map.get(ctx, :actor),
      # REAL authz threaded (never authorize?:false). Per-hop INTERMEDIATE authz is enforced by Ash
      # propagating this outer read's context.authorize? into the manual-rel %Context{}, consumed at
      # Traverse.authorize_nodes/authorized_read (traverse.ex:471-499) — NOT by this inner opt, which
      # passes the same value as redundant, fail-closed defense-in-depth (KEEP; see V4 and
      # project_relationship_aggregate_authz_mechanism). Ash always populates ctx.authorize? on the
      # inline entrypoint; the default here is FAIL-CLOSED (true), not false.
      authorize?: Map.get(ctx, :authorize?, true),
      tenant: Map.get(ctx, :tenant)
    ]

    # Load the manual Traverse rel with the aggregate's OWN destination query (filter + Ash-injected
    # policy) → Traverse Read B applies it; records come back already authorized/deduped/filtered/sorted.
    # agg.query may be nil (a count with no destination filter) → load the plain rel.
    load = if agg.query, do: [{rel, agg.query}], else: [rel]

    case Ash.load(records, load, load_opts) do
      {:ok, loaded} -> fold_and_put(loaded, rel, agg, types)
      {:error, error} -> {:error, traversal_aggregate_error(error)}
    end
  end

  defp load_and_attach(_records, %Ash.Query.Aggregate{relationship_path: path}, _source)
       when length(path) != 1,
       do:
         {:error,
          QueryFailed.exception(
            query: "ArcadeDB traversal aggregate",
            reason: "multi-segment relationship aggregate unsupported"
          )}

  @doc false
  # The DESTINATION resource's storage-type map for a single-segment relationship aggregate. The fold
  # operates on destination records (Traverse Read B), so guard_field/2 (binary/sensitive rejection)
  # and the min/max comparator must key off the DESTINATION's types, not the source being read. For a
  # self-referential traverse the destination IS the source; a cross-resource traverse diverges.
  # Public @doc false so the cross-resource regression test can assert the resolution directly.
  @spec aggregate_dest_types(Ash.Resource.t(), Ash.Query.Aggregate.t()) ::
          %{atom() => {Ash.Type.t(), keyword()}}
  def aggregate_dest_types(source, %Ash.Query.Aggregate{relationship_path: [rel]}),
    do: Info.attribute_types(Ash.Resource.Info.related(source, [rel]))

  defp fold_and_put(loaded, rel, agg, types) do
    Enum.reduce_while(loaded, {:ok, []}, fn record, {:ok, acc} ->
      dests = List.wrap(Map.get(record, rel))

      case AshArcadic.TraversalAggregate.fold(dests, agg, types) do
        {:ok, value} ->
          {:cont, {:ok, [put_agg(record, agg, value) | acc]}}

        # Wrap value-free as a QueryFailed (class :invalid), consistent with the multi-segment
        # branch — never a bare string (which Ash coerces to an :unknown/500-class error).
        {:error, reason} ->
          {:halt,
           {:error,
            QueryFailed.exception(
              query: "ArcadeDB traversal aggregate",
              reason: aggregate_reason(reason)
            )}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  # Attach per Ash's re-read contract (attach_fields): .load → direct field;
  # else → record.aggregates[name].
  defp put_agg(record, %Ash.Query.Aggregate{load: nil, name: name}, value),
    do: Map.update!(record, :aggregates, &Map.put(&1, name, value))

  defp put_agg(record, %Ash.Query.Aggregate{load: load}, value),
    do: Map.put(record, load, value)

  # Value-free (Rule 4): a traversal error already redacted by Traverse.load; wrap as a QueryFailed.
  defp traversal_aggregate_error(error) do
    QueryFailed.exception(query: "ArcadeDB traversal aggregate", reason: redact_db_error(error))
  end

  # Chain the two post-decode computed-field attachers: traversal aggregates, then calculations.
  # Short-circuits value-free on the first {:error, _}.
  defp attach_computed(records, aggs, calcs, resource) do
    with {:ok, records} <- attach_traversal_aggregates(records, aggs, resource) do
      attach_calculations(records, calcs, resource)
    end
  end

  # Compute each stashed expression calc in Elixir over the just-decoded records (flat RETURN n),
  # mirroring ETS do_add_calculations (ets.ex:695-760). add_calculations already fail-closed-gated the
  # refs, so eval only runs over stored, non-sensitive fields. Attach per Ash's re-read contract.
  defp attach_calculations(records, [], _resource), do: {:ok, records}

  defp attach_calculations(records, calcs, resource) do
    domain = Ash.Resource.Info.domain(resource)

    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case compute_calcs(record, calcs, resource, domain) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  defp compute_calcs(record, calcs, resource, domain) do
    Enum.reduce_while(calcs, {:ok, record}, fn {calc, expression}, {:ok, record} ->
      case eval_calc(record, calc, expression, resource, domain) do
        {:ok, value} -> {:cont, {:ok, put_calc(record, calc, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Hydrate the calc expression against the resource, then eval over the record.
  # Returns {:ok, value} | {:error, %QueryFailed{}} (value-free); :unknown → {:ok, nil} (ETS parity).
  # Ash's runtime eval calls Elixir primitives directly (String.*, arithmetic) with no try/rescue, so
  # a RAISE (ArithmeticError on a/0, an argument error over raw non-sensitive :binary bytes, a
  # protocol/encoder error) would otherwise propagate UNCAUGHT past the value-free wrapper and could
  # carry the offending value in its message (Rule 4; `project_redaction_fail_path_exception_leak`).
  # Rescue to a value-free error — `calc_error/1`'s `redact_db_error/1` maps any non-Arcadic error to
  # the fixed "ArcadeDB error" reason, so the raised message never reaches Ash/logs.
  defp eval_calc(record, calc, expression, resource, domain) do
    case Ash.Filter.hydrate_refs(expression, %{resource: resource, public?: false}) do
      {:ok, hydrated} -> eval_hydrated_calc(record, calc, hydrated, resource, domain)
      {:error, error} -> {:error, calc_error(error)}
    end
  rescue
    error -> {:error, calc_error(error)}
  end

  defp eval_hydrated_calc(record, calc, hydrated, resource, domain) do
    ctx = calc.context || %{}

    case Ash.Expr.eval_hydrated(hydrated,
           record: record,
           resource: resource,
           domain: domain,
           actor: Map.get(ctx, :actor),
           tenant: Map.get(ctx, :tenant)
         ) do
      {:ok, value} -> {:ok, value}
      :unknown -> {:ok, nil}
      {:error, error} -> {:error, calc_error(error)}
    end
  end

  # Attach per Ash's re-read contract (attach_fields): .load → direct field; else → record.calculations[name].
  defp put_calc(record, %Ash.Query.Calculation{load: nil, name: name}, value),
    do: Map.update!(record, :calculations, &Map.put(&1, name, value))

  defp put_calc(record, %Ash.Query.Calculation{load: load}, value),
    do: Map.put(record, load, value)

  # Value-free (Rule 4): redact any transport/eval error the value might ride.
  defp calc_error(error),
    do: QueryFailed.exception(query: "ArcadeDB calculation", reason: redact_db_error(error))

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
  def run_aggregate_query(%AshArcadic.Query{} = query, aggregates, resource) do
    Telemetry.span(
      :aggregate,
      %{
        resource: resource,
        multitenancy: strategy(resource),
        kinds: Enum.map(aggregates, & &1.kind),
        aggregate_count: length(aggregates),
        tenant?: not is_nil(query.tenant),
        in_transaction?: AshArcadic.Transaction.in_transaction?()
      },
      fn ->
        result = do_run_aggregate(query, resource, aggregates)
        {result, %{result: Telemetry.result_tag(result)}}
      end
    )
  end

  @impl true
  # Stash each relationship aggregate onto the query; run_query computes + attaches them over the
  # just-read parent records (add_aggregate receives NO records — Ash contract, ETS pattern).
  def add_aggregate(%AshArcadic.Query{aggregates: aggs} = query, aggregate, _resource),
    do: {:ok, %{query | aggregates: [aggregate | aggs]}}

  @impl true
  # Validate + stash each expression calculation. FAIL CLOSED value-free (before the query runs) on a
  # calc whose expression references a NON-STORED or `sensitive` field: the data layer only ever holds
  # the STORED value, and a `sensitive` field is app-side-encrypted ciphertext (AshCloak decrypts above
  # the data layer) — evaluating over it is wrong AND a redaction-leak surface. Operators are already
  # bounded by can?({:filter_expr, _}) at hydration; this adds the ref-classification bound. Supported
  # calcs compute in run_query (Elixir eval, mirroring ETS do_add_calculations; NOT Cypher).
  def add_calculations(%AshArcadic.Query{} = query, calcs, resource) do
    Enum.reduce_while(calcs, {:ok, query}, fn {calc, expression}, {:ok, q} ->
      if calc_supported?(expression, resource) do
        {:cont, {:ok, %{q | calculations: q.calculations ++ [{calc, expression}]}}}
      else
        {:halt,
         {:error,
          QueryFailed.exception(
            query: "ArcadeDB calculation",
            reason: "calculation references a non-stored or sensitive field"
          )}}
      end
    end)
  end

  # Every ref in the (calc-expanded) expression must be a LOCAL, stored, non-sensitive property.
  defp calc_supported?(expression, resource) do
    expression
    |> Ash.Filter.list_refs(false, false, true)
    |> Enum.all?(fn
      # A relationship-path ref (author.name) — a RELATED node's property, NOT a local n.<field>.
      # Evaluating it in run_query's Elixir eval triggers Ash's `Ash.load!(…, authorize?: false)`
      # fallback for the unloaded relationship (`Ash.Filter.Runtime.load_and_eval`), reading the
      # related resource WITHOUT its row/field policies (an authorization bypass — a leaf name that
      # collides with a source stored attr, e.g. `:id`, otherwise passes the name check below).
      # Reject value-free, mirroring `AshArcadic.Query.Expression`'s relationship-path rejection on
      # the filter/sort paths (load/filter/sort guards stay symmetric). Relationship/traversal calcs
      # are a spec §9 non-goal.
      %Ash.Query.Ref{relationship_path: [_ | _]} ->
        false

      %Ash.Query.Ref{attribute: %Ash.Resource.Attribute{name: name}} ->
        Info.value_translatable_field?(resource, name)

      %Ash.Query.Ref{attribute: name} when is_atom(name) ->
        Info.value_translatable_field?(resource, name)

      _ ->
        false
    end)
  end

  # Conn resolved SOLELY via read_conn/2 — a :context blank tenant fails closed
  # :tenant_required (never the base database → no unscoped cross-tenant aggregate).
  # :attribute carries Ash's injected tenant filter in query.filters. One statement per
  # aggregate (per-agg filters, C2); first failure halts value-free. read_conn/2 can also
  # yield :cross_database_transaction / :transaction_begin_failed (its @spec) when an
  # aggregate runs inside an Ash transaction; the catch-all maps those value-free via
  # conn_error_reason/1 — fail CLOSED, never a CaseClauseError on a multitenant read.
  defp do_run_aggregate(query, resource, aggregates) do
    # Slice 4: a standalone relationship aggregate (Ash.aggregate over a non-empty rel path) fails
    # closed value-free BEFORE resolving a conn — the per-node subtree rollup is delivered by the
    # inline load path (Ash.read(load: [:descendant_count])); the standalone cross-row collapse
    # semantics are unresolved, so ship no silent-wrong-result (spec §6.5 amendment, plan Task 4).
    # A MIXED flat+relationship batch (Ash splits aggregates only by :bypass, never by rel path)
    # fails the WHOLE call closed — a co-batched flat aggregate is collateral-rejected intentionally:
    # partitioning to run-flat + reject-rel would ship a partial result map alongside the error,
    # breaking reduce_aggregates' first-failure-halts convention (do NOT "fix" into a partition).
    if Enum.any?(aggregates, &(&1.relationship_path not in [nil, []])) do
      {:error,
       QueryFailed.exception(
         query: "ArcadeDB aggregate query",
         reason: aggregate_reason(:relationship_aggregate_standalone_unsupported)
       )}
    else
      case read_conn(query, resource) do
        {:ok, conn} ->
          reduce_aggregates(conn, query, aggregates, resource, Info.attribute_types(resource))

        {:error, :tenant_required} ->
          {:error,
           QueryFailed.exception(
             query: "ArcadeDB aggregate query",
             reason: "multitenancy tenant required for :context read"
           )}

        {:error, reason} ->
          {:error,
           QueryFailed.exception(
             query: "ArcadeDB aggregate query",
             reason: conn_error_reason(reason)
           )}
      end
    end
  end

  # One statement per aggregate (per-agg filters, C2); first failure halts value-free,
  # dropping the accumulated results (no partial map leaks past a failed aggregate).
  defp reduce_aggregates(conn, query, aggregates, resource, attr_types) do
    Enum.reduce_while(aggregates, {:ok, %{}}, fn agg, {:ok, acc} ->
      case run_one_aggregate(conn, query, agg, resource, attr_types) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, agg.name, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp run_one_aggregate(conn, query, agg, resource, attr_types) do
    with :ok <- validate_agg_field(agg, resource),
         :ok <- validate_agg_sort(agg, resource),
         {:ok, cypher, params} <- AshArcadic.Aggregate.build_statement(query, agg, attr_types) do
      run_aggregate_statement(conn, cypher, params, agg, attr_types)
    else
      {:error, reason} ->
        {:error,
         QueryFailed.exception(
           query: "ArcadeDB aggregate query",
           reason: aggregate_reason(reason)
         )}
    end
  end

  # Reject a VALUE-READING aggregate (sum/avg/min/max/first/list) over a field that is not a
  # STORED attribute — a `skip`-ped attribute (declared but never persisted) or a name that is
  # not an attribute at all. build_statement would otherwise emit e.g. `min(n.<field>)` over a
  # non-existent property → null → the Ash default (a silent wrong value). `count`/`exists` read
  # only presence and are always allowed (Aggregate.guard_field); a non-atom / nil field falls
  # through to guard_field (`:expression_field`). Same Info.stored_field?/2 guard as the sort
  # paths; guard_field then applies the per-kind storage-class check on the surviving stored field.
  defp validate_agg_field(%Ash.Query.Aggregate{kind: kind, field: field}, resource)
       when kind in [:sum, :avg, :min, :max, :first, :list] and is_atom(field) and
              not is_nil(field) do
    if Info.stored_field?(resource, field),
      do: :ok,
      else: {:error, {:unaggregatable_field, field}}
  end

  defp validate_agg_field(_agg, _resource), do: :ok

  # Reject a :first aggregate sort field that is not a STORED attribute (value-free). The
  # non-atom (calc/agg STRUCT) sort field is rejected inside Aggregate.build_statement
  # (guard_sort — the Rule-4 to_string leak guard); this covers a bare-atom sort field that
  # NAMES a calculation/aggregate or a `skip`-ped attribute (not an ArcadeDB property, so
  # `ORDER BY n.<field>` would sort by null → arbitrary first). Only :first consults query.sort;
  # same Info.stored_field?/2 guard as the record-read sort path (fail-closed, cross-path).
  defp validate_agg_sort(
         %Ash.Query.Aggregate{kind: :first, query: %{sort: [_ | _] = sort}},
         resource
       ) do
    Enum.reduce_while(sort, :ok, fn
      {field, _dir}, :ok when is_atom(field) ->
        if Info.stored_field?(resource, field),
          do: {:cont, :ok},
          else: {:halt, {:error, {:unsortable_sort_field, field}}}

      _entry, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_agg_sort(_agg, _resource), do: :ok

  defp run_aggregate_statement(conn, cypher, params, agg, attr_types) do
    case Arcadic.query(conn, cypher, params) do
      {:ok, rows} ->
        {:ok, AshArcadic.Aggregate.decode(rows, agg, attr_types)}

      {:error, error} ->
        {:error,
         QueryFailed.exception(query: "ArcadeDB aggregate query", reason: redact_db_error(error))}
    end
  end

  # Value-free reason strings — the atom/field NAME only, never a value (Rule 4).
  defp aggregate_reason({:unaggregatable, field, kind}),
    do:
      "aggregate #{kind} unsupported on field #{field} (non-numeric/non-orderable/sensitive storage)"

  defp aggregate_reason(:expression_field),
    do: "aggregate over an expression/calculation field is unsupported"

  defp aggregate_reason(:expression_sort),
    do: "aggregate :first sort over an expression/calculation field is unsupported"

  defp aggregate_reason({:unsortable_sort_field, field}),
    do: "aggregate :first sort field #{field} is not a stored attribute"

  defp aggregate_reason({:unaggregatable_field, field}),
    do: "aggregate field #{field} is not a stored attribute"

  defp aggregate_reason({:unsupported_kind, kind}), do: "aggregate kind #{kind} is unsupported"

  defp aggregate_reason({:include_nil_unsupported, kind}),
    do: "aggregate #{kind} with include_nil?: true is unsupported (ArcadeDB collect drops nulls)"

  # The traversal fold path (fold_and_put → TraversalAggregate.fold → safe_fold rescue) surfaces
  # this atom when a to_string/inspect/arith error over a mixed destination set is caught value-free.
  defp aggregate_reason(:aggregate_fold_failed), do: "aggregate computation failed"

  # Slice-4 closeout: the traversal fold rejects a field the destination's field policy redacted to
  # %Ash.ForbiddenField{} (an actor cannot aggregate a field they cannot read) — a field-authz
  # fail-closed. Value-free: names the field atom only, never a value (the marker carries none).
  defp aggregate_reason({:aggregate_field_forbidden, field}),
    do: "aggregate over field #{field} is forbidden by field policy"

  # Slice 4: a standalone relationship aggregate run through run_aggregate_query/3 (Ash.aggregate
  # over a non-empty relationship_path) fails closed BEFORE resolving a conn — the per-node subtree
  # rollup is delivered by the inline load path; the standalone cross-row collapse is unresolved, so
  # ship no silent-wrong-result. Value-free: names no rel/field (Rule 4).
  defp aggregate_reason(:relationship_aggregate_standalone_unsupported),
    do: "standalone relationship aggregates are unsupported; load the aggregate inline instead"

  # An aggregate carrying its OWN query.filter with an operator AshArcadic can't push down.
  # build_statement/3 → translate_agg_filter/2 propagates {:error, %UnsupportedFilter{}}.
  # The struct captures ONLY the operator module + field atom (never the filtered value —
  # unsupported_filter.ex contract), so both are value-free to name (Rule 4).
  #
  # These heads EXHAUSTIVELY cover the two callers' {:error, _} surfaces: build_statement/3
  # (via run_one_aggregate) — guard_field/2 yields the three tuple/atom shapes above and
  # translate_agg_filter/2 yields %UnsupportedFilter{}; AND the traversal fold path
  # (fold_and_put → TraversalAggregate.fold) — guard_field/2 (same shapes) plus safe_fold's
  # rescue, which contributes the extra :aggregate_fold_failed head above. No defensive _other
  # catch-all — dialyzer proves the union is closed (a dead clause reds pattern_match_cov). A
  # future error shape from EITHER caller reopens dialyzer coverage here rather than passing
  # through a dead clause — a stronger fail-closed guarantee than a catch-all that can never run.
  # The FunctionClauseError this task fixes came from a MISSING head (%UnsupportedFilter{}), now present.
  defp aggregate_reason(%UnsupportedFilter{operator: operator, field: field}),
    do:
      "aggregate filter uses unsupported operator #{inspect(operator)} on field #{inspect(field)}"

  @impl true
  def create(resource, changeset) do
    Telemetry.span(:create, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_create(resource, changeset)

      {result,
       %{
         tenant?: tenant?(changeset),
         result: Telemetry.result_tag(result),
         in_transaction?: AshArcadic.Transaction.in_transaction?()
       }}
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
         result: Telemetry.result_tag(result),
         in_transaction?: AshArcadic.Transaction.in_transaction?()
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

      {result,
       %{
         tenant?: tenant?(changeset),
         result: Telemetry.result_tag(result),
         in_transaction?: AshArcadic.Transaction.in_transaction?()
       }}
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
         result: Telemetry.result_tag(result),
         in_transaction?: AshArcadic.Transaction.in_transaction?()
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
         result: Telemetry.result_tag(result),
         in_transaction?: AshArcadic.Transaction.in_transaction?()
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
        case Filter.translate(filter, %AshArcadic.Query{
               params: params,
               resource: changeset.resource
             }) do
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
