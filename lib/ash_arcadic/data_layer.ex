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
  alias Ash.Actions.Sort
  alias Ash.Error.Changes.StaleRecord
  alias AshArcadic.Cast
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Errors.CreateFailed
  alias AshArcadic.Errors.QueryFailed
  alias AshArcadic.Errors.UnsupportedFilter
  alias AshArcadic.Errors.UpdateFailed
  alias AshArcadic.Query.Combination
  alias AshArcadic.Query.Expression
  alias AshArcadic.Query.Filter
  alias AshArcadic.Query.Write
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

  @vector_index_entity %Spark.Dsl.Entity{
    name: :vector_index,
    describe:
      "Declares a dense vector index on an attribute (metadata only — the host creates the index).",
    args: [:name],
    target: AshArcadic.VectorIndex,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The vector attribute (a stored, non-sensitive, array-typed property)."
      ],
      dimensions: [
        type: :pos_integer,
        required: true,
        doc: "Embedding dimensionality (must equal the search vector's length)."
      ],
      similarity: [
        type: {:one_of, [:cosine, :dot_product, :euclidean]},
        default: :cosine,
        doc: "Distance metric — drives `distance`/`max_distance` semantics."
      ]
    ]
  }

  @sparse_vector_index_entity %Spark.Dsl.Entity{
    name: :sparse_vector_index,
    describe:
      "Declares a sparse vector index over a (tokens, weights) attribute pair (metadata only — the host creates the index).",
    args: [:name],
    target: AshArcadic.SparseVectorIndex,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "A logical index name (referenced by the vector-search preparation)."
      ],
      tokens: [
        type: :atom,
        required: true,
        doc: "The integer-array attribute holding token ids (stored, non-sensitive)."
      ],
      weights: [
        type: :atom,
        required: true,
        doc: "The float-array attribute holding the matching weights (stored, non-sensitive)."
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
    entities: [@edge_entity, @vector_index_entity, @sparse_vector_index_entity]
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
      AshArcadic.DataLayer.Verifiers.ValidateRelationshipFk,
      AshArcadic.DataLayer.Verifiers.ValidateVectorIndex,
      AshArcadic.DataLayer.Verifiers.ValidateSparseVectorIndex
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
  # Slice 9: query-scoped bulk writes. :update_query enables the one-statement push-down
  # (Ash's set_strategy, update/bulk.ex:1211, drops to [:stream] when false). :expr_error
  # signals we surface expression errors so Ash keeps the FULL atomic strategy set incl. pure
  # :atomic (else it drops to [:stream, :atomic_batches, :atomic] — spec §3/D7).
  def can?(_, :update_query), do: true
  def can?(_, :expr_error), do: true
  def can?(_, :destroy_query), do: true
  # :update_many enables the heterogeneous per-record push-down (Ash groups changesets by
  # {atomics, filter} and hands each group to update_many/3; a shared-atomic fold + a per-row
  # UNWIND MATCH keyed by PK applies each row's own static changes in one statement).
  def can?(_, :update_many), do: true
  # Slice 9 / D9: false — a batch write is whole-batch atomic with NO per-row attribution, so we
  # cannot produce Ash's {:partial_success, failed, succeeded} return. Probe (throwaway db,
  # scratchpad/probe_partial_success.exs): a SQL-DDL `CREATE INDEX … UNIQUE` DOES enforce (a single
  # Cypher dup CREATE → DuplicatedKeyException/409 — this REFINES P6, whose non-enforcement was a
  # Cypher-DDL artifact), but an UNWIND CREATE batch [new1, a(dup), new2] aborts ALL-OR-NOTHING
  # (row count unchanged at 1 — the valid new1/new2 rolled back too) and the error is a bare
  # DuplicatedKeyException/409 that never names WHICH row failed. No partial commit + no attribution
  # ⇒ partial success infeasible; false = Ash never expects the {:partial_success, …} return.
  def can?(_, :bulk_create_with_partial_success), do: false
  # Slice 9: atomic SET surface. {:atomic, :update} lets Ash use the pure :atomic strategy for
  # bulk update; {:atomic, :create}/{:atomic, :upsert} let an atomic_set on a create/upsert reach
  # create/2/upsert/3 — which now FOLD changeset.create_atomics/atomics into the statement (V8).
  def can?(_, {:atomic, :update}), do: true
  def can?(_, {:atomic, :create}), do: true
  def can?(_, {:atomic, :upsert}), do: true
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
  def can?(_, :distinct), do: true
  def can?(_, :distinct_sort), do: true
  def can?(_, :combine), do: true

  def can?(_, {:combine, type}) when type in [:base, :union, :union_all, :intersect, :except],
    do: true

  def can?(_, {:combine, _}), do: false
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
  # A CONSTANT-FOLDED expression: Operator.new/3 evaluates an all-literal call at hydration
  # (100 + 1 → 101) and hydrate_refs then asks {:filter_expr, <literal>} (deps/ash
  # filter.ex:3668/3677 — live-hit by atomic_set(:count, expr(100 + 1)) on create, Slice 9).
  # A bare literal is always translatable — Expression.translate binds it as $paramN.
  def can?(_, {:filter_expr, value}) when not is_struct(value), do: true
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

  # Vector search rides a normal read action (a preparation stashes it); Ash issues no `can?`
  # for it, so this is documentary/telemetry-facing, not a load-bearing gate.
  def can?(_, :vector_search), do: true
  def can?(_, {:vector_search, :dense}), do: true
  def can?(_, {:vector_search, :sparse}), do: true
  def can?(_, {:vector_search, :hybrid}), do: true

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
         internal?: get_in(context, [:private, :internal?]) == true,
         vector_search: get_in(context, [:vector_search])
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

  # The exact qualifier set the render handles faithfully (Query.order_by_expr/order_dir clauses,
  # all six pinned by the D12 ORDER-BY test) — identical to Ash's parse_sort allowlist
  # (deps/ash sort.ex:161-168). Anything else falls into order_dir's `_ → ASC` catch-all → a
  # silently wrong order, so the sort and distinct FIELD-ENTRY guards clamp directions to this
  # set (the {name, direction} branch below; distinct/3 likewise). The expr-calc sort branch does
  # NOT clamp — a bogus direction on a %Ash.Query.Calculation{} entry rides order_dir's ASC
  # coercion; that render-catch-all path is not callback-reachable (parse_sort gates every entry's
  # direction upstream) and is the pre-existing shared-helper behavior routed to Plan 2 (closeout
  # N13). Matters most for distinct_sort: Ash.Query.distinct_sort/3 appends RAW entries (no
  # Sort.process → no upstream InvalidSortOrder, unlike sort/distinct — live-probed), so the
  # clamp is the only line of defense there; on sort/distinct it is defense-in-depth.
  @sort_directions [
    :asc,
    :asc_nils_first,
    :asc_nils_last,
    :desc,
    :desc_nils_first,
    :desc_nils_last
  ]

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
        cond do
          not Info.stored_field?(resource, name) ->
            {:error, sort_error("sort field #{name} is not a stored attribute")}

          direction not in @sort_directions ->
            {:error, sort_error("sort direction for field #{name} is not a supported sort order")}

          true ->
            {:ok, query, {name, direction}}
        end

      :expression ->
        {:error,
         sort_error(
           "sort over an expression, calculation, or non-atom field entry is unsupported"
         )}
    end
  end

  # {name, direction} for a stored-attribute sort entry (atom or the resolved
  # %Ash.Resource.Attribute{} form Ash passes); :expression for a calculation/aggregate
  # STRUCT field (non-atom) — not a Cypher-expressible property, rejected value-free.
  # The is_atom guard also catches a hand-crafted %Attribute{} carrying a non-atom name
  # (distinct_sort's RAW ingress): without it the term escapes into stored_field?'s
  # is_atom clause / the direction reject's interpolation as an UNCONTROLLED crash
  # carrying the caller's term (closeout security note) — route it to the static reject.
  defp normalize_sort_entry({%Ash.Resource.Attribute{name: name}, direction})
       when is_atom(name),
       do: {name, direction}

  defp normalize_sort_entry({name, direction}) when is_atom(name), do: {name, direction}
  defp normalize_sort_entry(_entry), do: :expression

  # Value-free: `reason` names only the field atom / a static string — never a value (Rule 4).
  defp sort_error(reason), do: QueryFailed.exception(query: "ArcadeDB sort", reason: reason)

  @impl true
  # DISTINCT scoping path — fails CLOSED. Through the Ash API, Ash.Query.distinct/2 gates on the bare
  # can?(:distinct) atom AND runs Sort.process, whose type_sortable? check already rejects
  # :binary/:decimal storage upstream via can?({:sort, storage}) (deps/ash sort.ex:255/449;
  # live-probed: UnsortableField for :secret/:amount) — but it ACCEPTS a `skip`-ped attribute
  # (live-probed) and turns calc names into %Calculation{} structs. So this guard is the SOLE defense
  # for the NON-STORED class (n.<f> is null → wrong grouping) and the calc/rel STRUCT class (not
  # renderable as n.<f>, symmetric with sort_clause's :expression reject and calc_supported?/2). The
  # `sensitive` reject (AshCloak random-IV ciphertext never dedups equal plaintext → a correctness
  # bug, not just a leak) is defense-in-depth: sensitive ⇒ binary-storage-or-skipped (verifier), both
  # rejected en route, so it fires only on a direct data-layer call. A :binary/:decimal distinct
  # FIELD is accepted HERE (dedup is equality, byte order irrelevant) — unreachable via the Ash API.
  # Accepted entries are stashed NORMALIZED ({name, dir}) so the render never sees a struct field.
  def distinct(%AshArcadic.Query{} = query, distinct, resource) do
    case validate_distinct(distinct, resource, reject_sensitive: true, reject_unsortable: false) do
      {:ok, normalized} -> {:ok, %{query | distinct: normalized}}
      {:error, _} = err -> err
    end
  end

  @impl true
  # DISTINCT-SORT scoping path — picks WHICH representative row survives per distinct group. Same
  # entry-shape guard PLUS the :binary/:decimal reject the record-read sort path applies (base64 order
  # != byte order; lexicographic decimal != numeric → a silently wrong representative). Unlike
  # distinct/sort, Ash.Query.distinct_sort/3 does NOT run Sort.process (query.ex:4293 appends raw
  # entries — no upstream type_sortable?/field-existence gate), so this guard is the SOLE
  # storage/class defense on the distinct_sort path. Reuses the can?({:sort, storage}) sortability
  # decision so distinct_sort and sort stay identical on storage; stashes NORMALIZED ({name, dir}).
  # `sensitive` is closed here TRANSITIVELY (no reject_sensitive clause): ValidateSensitive R2
  # forces sensitive ⇒ :binary-storage-or-skipped, so a sensitive entry always dies in the
  # non-stored or unsortable-storage clause — if R2 ever admitted a sortable sensitive storage,
  # add reject_sensitive: true here (a ciphertext ORDER BY is a byte-order oracle).
  def distinct_sort(%AshArcadic.Query{} = query, distinct_sort, resource) do
    case validate_distinct(distinct_sort, resource,
           reject_sensitive: false,
           reject_unsortable: true
         ) do
      {:ok, normalized} -> {:ok, %{query | distinct_sort: normalized}}
      {:error, _} = err -> err
    end
  end

  # Entry-shape + classification guard shared by distinct/3 and distinct_sort/3. Returns
  # {:ok, normalized}: each accepted entry is normalize_sort_entry's {name, dir} — the
  # %Ash.Resource.Attribute{} form is normalized INTO the stash (mirroring sort/3's stash) so the
  # render's Identifier.validate! never sees a struct; any calc/aggregate STRUCT field maps to
  # :expression (value-free reject).
  defp validate_distinct(entries, resource, opts) do
    reject_sensitive? = Keyword.fetch!(opts, :reject_sensitive)
    reject_unsortable? = Keyword.fetch!(opts, :reject_unsortable)

    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case validate_distinct_entry(entry, resource, reject_sensitive?, reject_unsortable?) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  # Classifies ONE entry fail-closed: unknown direction / non-stored / (optionally) sensitive /
  # (optionally) unsortable-storage / calc-or-aggregate STRUCT (:expression) — all rejected
  # value-free (the direction reject names only the FIELD; the direction itself is an arbitrary
  # caller term). Accepts with the NORMALIZED {name, dir} form.
  defp validate_distinct_entry(entry, resource, reject_sensitive?, reject_unsortable?) do
    with {name, dir} <- normalize_sort_entry(entry),
         :ok <- validate_direction(name, dir),
         :ok <- validate_distinct_field(name, resource, reject_sensitive?, reject_unsortable?) do
      {:ok, {name, dir}}
    else
      :expression ->
        {:error,
         distinct_error(
           "distinct over an expression, calculation, or non-atom field entry is unsupported"
         )}

      {:error, _} = err ->
        err
    end
  end

  defp validate_direction(name, dir) do
    if dir in @sort_directions do
      :ok
    else
      {:error,
       distinct_error("distinct direction for field #{name} is not a supported sort order")}
    end
  end

  defp validate_distinct_field(name, resource, reject_sensitive?, reject_unsortable?) do
    cond do
      not Info.stored_field?(resource, name) ->
        {:error, distinct_error("distinct field #{name} is not a stored attribute")}

      reject_sensitive? and name in Info.sensitive(resource) ->
        {:error, distinct_error("distinct over sensitive field #{name} is unsupported")}

      reject_unsortable? and not sortable_storage?(resource, name) ->
        {:error, distinct_error("distinct sort field #{name} has an unsortable storage type")}

      true ->
        :ok
    end
  end

  # Reuses the record-read sort's storage-sortability decision (can?({:sort, storage})): :binary and
  # :decimal are false (base64/lexicographic order is not the value order), everything else true.
  defp sortable_storage?(resource, name) do
    {type, constraints} = Map.fetch!(Info.attribute_types(resource), name)
    can?(resource, {:sort, Ash.Type.storage_type(type, constraints)})
  end

  # Value-free (Rule 4): names only the field atom / a static string — never a value.
  defp distinct_error(reason),
    do: QueryFailed.exception(query: "ArcadeDB distinct", reason: reason)

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
         calculation_count: length(query.calculations),
         distinct?: query.distinct != [],
         combination?: query.combination_of != [],
         combination_types: Enum.map(query.combination_of, &elem(&1, 0)),
         combination_strategy: combination_strategy(query.combination_of),
         vector_search?: not is_nil(query.vector_search),
         vector_kind: vector_kind(query.vector_search)
       }}
    end)
  end

  # Vector search (dense kNN) — a SEPARATE ArcadeDB SQL path (Arcadic.Vector.neighbors), NOT the
  # Cypher engine. Matched FIRST so a query carrying BOTH combination_of and vector_search fails
  # closed here (vector_reject_combination), never silently one-or-the-other. Tenant scoping keys on
  # strategy + tenant + allow_global? (NEVER filter-emptiness) and SELF-INJECTS the :attribute tenant
  # predicate — a :bypass action yields non-empty filters WITHOUT a tenant predicate, so filter
  # presence is not a safe scoping signal (Slice-10 plan-review #2). Scope-error atoms are wrapped
  # value-free.
  defp do_run_query(%AshArcadic.Query{vector_search: vs} = query, resource) when is_map(vs) do
    with :ok <- vector_reject_combination(query),
         :ok <- vector_reject_kind(vs),
         :ok <- vector_reject_malformed(vs),
         :ok <- vector_reject_computed(query),
         :ok <- vector_reject_paging(query),
         {:ok, mode} <- vector_scope_mode(query, resource, vs),
         {:ok, conn} <- read_conn(query, resource),
         {:ok, rows} <- run_vector_search(conn, query, resource, vs, mode) do
      {:ok, decode_neighbor_rows(resource, rows)}
    else
      {:error, atom} when is_atom(atom) -> {:error, vector_error(atom)}
      {:error, other} -> {:error, other}
    end
  end

  # Aggregates/calculations OVER a combination are not supported this slice — fail closed value-free
  # rather than silently drop them. Ash runs add_aggregates/add_calculations on the combined
  # data_layer_query (deps/ash read.ex:1781-1789), so a combination read that loads a relationship
  # aggregate or a calculation reaches here with both set; the plain combination clause below returns
  # decode_records WITHOUT attach_computed, which would silently omit the loaded aggregate/calc.
  defp do_run_query(%AshArcadic.Query{combination_of: [_ | _], aggregates: [_ | _]}, _resource) do
    {:error,
     QueryFailed.exception(
       query: "ArcadeDB combination query",
       reason: "aggregates over a combination are not supported"
     )}
  end

  defp do_run_query(%AshArcadic.Query{combination_of: [_ | _], calculations: [_ | _]}, _resource) do
    {:error,
     QueryFailed.exception(
       query: "ArcadeDB combination query",
       reason: "calculations over a combination are not supported"
     )}
  end

  defp do_run_query(%AshArcadic.Query{combination_of: [_ | _]} = query, resource) do
    case read_conn(query, resource) do
      {:ok, conn} ->
        run_combination(conn, query, resource)

      {:error, :tenant_required} ->
        {:error,
         QueryFailed.exception(
           query: "ArcadeDB read query",
           reason: "multitenancy tenant required for :context read"
         )}
    end
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

  # === Vector search (dense kNN) — Slice 10 Plan 1 ===

  @default_max_vector_candidates 10_000

  defp vector_reject_combination(%AshArcadic.Query{combination_of: [_ | _]}),
    do: {:error, vector_failed("combinations over a vector search are not supported")}

  defp vector_reject_combination(_), do: :ok

  defp vector_reject_kind(%{kind: kind}) when kind in [:dense, :sparse, :hybrid], do: :ok

  defp vector_reject_kind(_),
    do: {:error, vector_failed("unsupported vector search kind")}

  # The stash comes from the query CONTEXT (public `Ash.Query.set_context`), so a caller can craft a
  # malformed one. Validate the SHAPE fail-closed value-free (CV-2/CV-3) — otherwise a missing key
  # later dot-accesses (KeyError inspecting `vs`, leaking the query vector — Rule 4), and a non-boolean
  # `allow_global?` would pass the truthiness scope check and open a global kNN. Each head PINS its
  # `kind` so kind+shape validate together (B1 plan-review — a `kind: _` wildcard would accept a
  # mis-kinded stash whose dispatch then KeyError-leaks the query values).
  # Non-empty-list keys use the `[_ | _]` PATTERN (asserts list-and-non-empty in one match, no
  # `is_list … and … != []` guard pair).
  defp vector_reject_malformed(%{
         kind: :dense,
         index: index,
         query_vector: [_ | _],
         k: k,
         allow_global?: allow_global?,
         opts: opts
       })
       when is_atom(index) and is_integer(k) and k > 0 and is_boolean(allow_global?) and
              is_list(opts),
       do: :ok

  defp vector_reject_malformed(%{
         kind: :sparse,
         index: index,
         tokens_property: tp,
         weights_property: wp,
         query_tokens: [_ | _],
         query_weights: [_ | _],
         k: k,
         allow_global?: allow_global?,
         opts: opts
       })
       when is_atom(index) and is_atom(tp) and is_atom(wp) and
              is_integer(k) and k > 0 and is_boolean(allow_global?) and is_list(opts),
       do: :ok

  # Hybrid: `arms` a list of length ≥ 2 (fuse requires ≥2 sources), each a valid per-kind arm map.
  defp vector_reject_malformed(%{
         kind: :hybrid,
         arms: arms,
         allow_global?: allow_global?,
         opts: opts
       })
       when is_list(arms) and is_boolean(allow_global?) and is_list(opts) do
    if length(arms) >= 2 and Enum.all?(arms, &valid_fuse_arm?/1),
      do: :ok,
      else: {:error, vector_failed("malformed vector search request")}
  end

  defp vector_reject_malformed(_),
    do: {:error, vector_failed("malformed vector search request")}

  defp valid_fuse_arm?(%{kind: :dense, property: p, query_vector: [_ | _], k: k})
       when is_atom(p) and is_integer(k) and k > 0,
       do: true

  defp valid_fuse_arm?(%{
         kind: :sparse,
         tokens_property: tp,
         weights_property: wp,
         query_tokens: [_ | _],
         query_weights: [_ | _],
         k: k
       })
       when is_atom(tp) and is_atom(wp) and is_integer(k) and k > 0,
       do: true

  defp valid_fuse_arm?(%{kind: :fulltext, property: p, text_query: tq, k: k})
       when is_atom(p) and is_binary(tq) and tq != "" and is_integer(k) and k > 0,
       do: true

  defp valid_fuse_arm?(_), do: false

  defp vector_reject_computed(%AshArcadic.Query{aggregates: [_ | _]}),
    do: {:error, vector_failed("aggregates over a vector search are not supported")}

  defp vector_reject_computed(%AshArcadic.Query{calculations: [_ | _]}),
    do: {:error, vector_failed("calculations over a vector search are not supported")}

  defp vector_reject_computed(_), do: :ok

  # A set limit, or a non-spurious offset. Ash injects `offset: 0` spuriously on paginated reads
  # (query.ex build_skip(0) → []), so treat 0 as unset — else every paginated action would reject.
  defp vector_reject_paging(%AshArcadic.Query{limit: nil, offset: offset})
       when offset in [nil, 0],
       do: :ok

  defp vector_reject_paging(_),
    do:
      {:error,
       vector_failed("limit/offset are not supported on a vector search (k is the bound)")}

  # Scope resolution — keyed on strategy + tenant + allow_global?, NEVER on filter-emptiness.
  defp vector_scope_mode(query, resource, vs) do
    case {strategy(resource), blank_tenant?(query.tenant)} do
      {:attribute, false} ->
        {:ok, :scoped}

      {:attribute, true} ->
        # STRICT `== true` (not truthiness) — a non-boolean allow_global? is already rejected by
        # vector_reject_malformed, but keep the scope gate itself strict so only a real opt-in opens
        # global (CV-2). Map.get keeps it value-free (never dot-accesses a malformed stash).
        if(Map.get(vs, :allow_global?, false) == true,
          do: {:ok, :global},
          else: {:error, :tenant_required}
        )

      # :context blank tenant is caught by read_conn (:tenant_required); allow_global? is N/A.
      {:context, _} ->
        {:ok, :scoped}

      # Non-multitenant: no tenancy to enforce — a global kNN is correct, not a crash/reject.
      {nil, _} ->
        {:ok, :global}
    end
  end

  defp blank_tenant?(tenant), do: tenant in [nil, ""]

  # :attribute scoped → SELF-INJECT the tenant predicate (never trust query.filters); always
  # candidate-set. Otherwise: unfiltered :context/:global → direct kNN; filtered → candidate-set
  # (caller/policy filters via build_where; :context is DB-scoped, :global has no tenant). The
  # property/tokens/weights come from the (already malformed-guarded) stash PER-KIND inside
  # `run_vector_kind` — `run_vector_search` never dot-accesses `vs.index` (a hybrid stash has none;
  # S1 plan-review).
  defp run_vector_search(conn, query, resource, vs, mode) do
    type = to_string(Info.label(resource))

    tenant_pred =
      if mode == :scoped and strategy(resource) == :attribute,
        do: vector_tenant_predicate(resource, query.tenant),
        else: nil

    if query.filters == [] and is_nil(query.expression) and is_nil(tenant_pred) do
      run_vector_kind(conn, type, vs, [])
    else
      vector_candidate_search(conn, query, type, vs, tenant_pred)
    end
  end

  defp vector_candidate_search(conn, query, type, vs, tenant_pred) do
    {cypher, params} = AshArcadic.Query.candidate_rid_cypher(query, tenant_pred)

    case Arcadic.query(conn, cypher, params) do
      {:ok, rows} ->
        rids = rows |> Enum.map(&Map.get(&1, "@rid")) |> Enum.reject(&is_nil/1)

        # Value-free observability (count only, no row/tenant value) — lets an operator watch the
        # candidate set approach max_vector_candidates before the R2 ceiling trips as a hard error.
        :telemetry.execute([:ash_arcadic, :vector, :candidate_count], %{count: length(rids)}, %{})

        cond do
          rids == [] ->
            # Fail-closed: an empty scoped candidate set means NO in-scope rows — never a global kNN.
            {:ok, []}

          length(rids) > max_vector_candidates() ->
            # Reject, NEVER truncate — truncation would drop the true nearest neighbour silently.
            {:error,
             vector_failed("scoped candidate set exceeds max_vector_candidates; narrow the read")}

          true ->
            run_vector_kind(conn, type, vs, filter: rids)
        end

      {:error, error} ->
        {:error, vector_failed(redact_db_error(error))}
    end
  end

  # Runs the kind-appropriate arcadic search with the optional candidate-set `filter:` prepended.
  # `[filter: rids] ++ vs.opts` — NOT `filter: rids ++ vs.opts` (the latter concatenates opts onto
  # the RID list and validate_rids! raises). The malformed guard has already validated k/vectors/
  # tokens/weights/arms, so the arcadic client-side raises (require_pos_int!, ≥2 sources) cannot fire.
  defp run_vector_kind(conn, type, %{kind: :dense} = vs, filter_opts) do
    conn
    |> Arcadic.Vector.neighbors(
      type,
      to_string(vs.index),
      vs.query_vector,
      vs.k,
      filter_opts ++ vs.opts
    )
    |> wrap_vector()
  end

  defp run_vector_kind(conn, type, %{kind: :sparse} = vs, filter_opts) do
    Arcadic.Vector.sparse_neighbors(
      conn,
      type,
      to_string(vs.tokens_property),
      to_string(vs.weights_property),
      vs.query_tokens,
      vs.query_weights,
      vs.k,
      filter_opts ++ vs.opts
    )
    |> wrap_vector()
  end

  defp run_vector_kind(conn, type, %{kind: :hybrid} = vs, filter_opts) do
    specs = Enum.map(vs.arms, &fuse_arm_spec(type, &1))

    conn
    |> Arcadic.Vector.fuse(specs, filter_opts ++ vs.opts)
    |> wrap_vector()
  end

  defp wrap_vector({:ok, rows}), do: {:ok, rows}
  defp wrap_vector({:error, error}), do: {:error, vector_failed(redact_db_error(error))}

  # S3 plan-review: the DENSE fuse arm is the UNTAGGED `{type, property, vec, k}` tuple — a tagged
  # `{:dense, …}` falls to arcadic's raising fallback (`vector.ex:426`); type/property MUST be strings
  # (`is_binary`-guarded). Sparse/fulltext arms are tagged.
  defp fuse_arm_spec(type, %{kind: :dense, property: p, query_vector: qv, k: k}),
    do: {type, to_string(p), qv, k}

  defp fuse_arm_spec(type, %{
         kind: :sparse,
         tokens_property: tp,
         weights_property: wp,
         query_tokens: qt,
         query_weights: qw,
         k: k
       }),
       do: {:sparse, type, to_string(tp), to_string(wp), qt, qw, k}

  defp fuse_arm_spec(type, %{kind: :fulltext, property: p, text_query: tq, k: k}),
    do: {:fulltext, type, to_string(p), tq, k}

  # Composes `n.<attr> = $vtenant` from the resource's multitenancy attribute + the ToTenant-normalized
  # tenant (S9P2 CV-5), mirroring update_many_scope/3. The attribute NAME is identifier-validated;
  # the tenant VALUE binds as $vtenant (params-only).
  defp vector_tenant_predicate(resource, tenant) do
    attr = Ash.Resource.Info.multitenancy_attribute(resource)
    {m, f, a} = Ash.Resource.Info.multitenancy_parse_attribute(resource)
    raw = apply(m, f, [Ash.ToTenant.to_tenant(tenant, resource) | a])

    # SERIALIZE to the STORED representation (CV-1) — the write path stores the discriminator via
    # Cast.serialize_value (Base64 for a :binary type) and the flat read binds the same
    # (filter.ex cast_value → Cast.serialize_value); this predicate must match. DEFENSIVE PARITY:
    # the only type where serialize ≠ raw ON THE WIRE is :binary, which ValidateMultitenancyAttr
    # COMPILE-FORBIDS as a discriminator ("plaintext comparator"); every other reachable type
    # coincides (string/uuid/integer identity; date/datetime/decimal share a Jason encoder). So this
    # is a no-op for every ALLOWED discriminator today — kept for correctness and to stay closed if
    # that verifier ever changes. See project memory vector_search_self_injection_and_stash_validation.
    value = Cast.serialize_value(raw, Info.attribute_types(resource)[attr])
    attr_name = attr |> to_string() |> AshArcadic.Identifier.validate!()
    {"n.#{attr_name} = $vtenant", %{"vtenant" => value}}
  end

  # Validated pos-integer (CV-4) — a misconfigured value (string "10000", nil, :infinity) makes
  # `length(rids) > value` fail OPEN under Erlang term ordering, disabling the ceiling. Fall back to
  # the safe default for any non-pos-integer config.
  defp max_vector_candidates do
    case Application.get_env(:ash_arcadic, :max_vector_candidates, @default_max_vector_candidates) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_vector_candidates
    end
  end

  defp vector_failed(reason),
    do: QueryFailed.exception(query: "ArcadeDB vector search", reason: reason)

  # Wraps a bare scope/conn error atom value-free (read_conn only yields :tenant_required here).
  defp vector_error(:tenant_required),
    do: vector_failed("multitenancy tenant required for a vector search")

  defp vector_error(_atom), do: vector_failed("vector search failed")

  # Value-free telemetry tag: the vector-search kind (an atom, never row data), nil for a non-vector read.
  defp vector_kind(%{kind: kind}), do: kind
  defp vector_kind(_), do: nil

  # Decodes neighbors rows. Captures the rank metadata BEFORE decode_records strips undeclared keys:
  # dense rows carry a `distance` (→ :vector_distance); sparse/hybrid rows carry a `score`
  # (→ :vector_score, higher = better). A fuse row carries a `distance` KEY that is `nil` (it ranks by
  # `score`), so each capture is gated `is_number` — a nil distance is skipped, never attached. Rank
  # order (best-first) is preserved. Never reads the broken nested `record` map (top-level only).
  defp decode_neighbor_rows(resource, rows) do
    attribute_map = Info.attribute_map(resource)
    attribute_types = Info.attribute_types(resource)

    Enum.map(rows, fn row ->
      resource
      |> struct(Cast.row_to_attrs(row, attribute_map, attribute_types))
      |> put_rank_metadata(:vector_distance, Map.get(row, "distance"))
      |> put_rank_metadata(:vector_score, Map.get(row, "score"))
    end)
  end

  defp put_rank_metadata(record, key, value) when is_number(value),
    do: Ash.Resource.put_metadata(record, key, value)

  defp put_rank_metadata(record, _key, _value), do: record

  # Native (all union-family, no per-branch paging) → one CALL{UNION} statement via to_cypher. In-memory
  # (any intersect/except, OR any per-branch limit/offset) → run each branch, PK-fold, apply outer modifiers
  # in Elixir. combination_unsupported/2 fails closed value-free on shapes neither path can honor.
  defp run_combination(conn, query, resource) do
    in_memory? = combination_in_memory?(query.combination_of)

    case combination_unsupported(query, in_memory?) do
      nil ->
        if in_memory?,
          do: run_inmemory_combination(conn, query, resource),
          else: run_native_combination(conn, query, resource)

      reason ->
        {:error, QueryFailed.exception(query: "ArcadeDB combination query", reason: reason)}
    end
  end

  # The in-memory strategy runs when any branch is intersect/except (ArcadeDB has no INTERSECT/EXCEPT) OR
  # any branch carries per-branch paging (a limit / positive offset). Per-branch paging forces in-memory
  # because the native CALL-wrap applies the outer (tenant) filter AFTER the union, so a branch LIMIT would
  # fill from cross-tenant rows the outer WHERE then trims (under-return); the in-memory `run_branch` pushes
  # the outer filter INTO each branch, so the branch LIMIT sees only the tenant's rows. Whole-vertex UNION
  # dedup ≡ PK-fold dedup for PK-bearing resources (spec §7.2), so the strategy switch is result-equivalent.
  defp combination_in_memory?(combination_of) do
    not Combination.native?(combination_of) or Enum.any?(combination_of, &branch_paged?/1)
  end

  # Fail closed value-free on combination shapes NEITHER path can honor (Ash CAN construct them —
  # combination_queries applies per-branch limit/offset/sort/calculations, deps/ash query.ex:4607-4621).
  # Per-branch calculations are rejected on both paths (the whole-vertex `RETURN n` render drops them). An
  # expr-calc outer sort and a lazy outer :expression are rejected on the IN-MEMORY path — the native render
  # honors both (order_fragment / build_where), but the in-memory path passes query.sort to
  # Ash.Actions.Sort.runtime_sort (which FunctionClauseErrors on a {:expr,_,_} 3-tuple, value-leaking the
  # record list, sort.ex:117,123) and never consults query.expression. All reasons are fixed literals.
  defp combination_unsupported(query, in_memory?) do
    cond do
      Enum.any?(query.combination_of, &branch_has_calculations?/1) ->
        "calculations on a combination branch are not supported"

      # A branch expr-calc SORT is rejected on both paths: rekey_branch/3 namespaces only the branch's
      # WHERE clauses + params, so a {:expr, cypher, dir} branch-sort fragment keeps its ORIGINAL $paramN
      # ref while the branch params are renamed to b<i>_paramN — the orphaned ref would mis-bind against
      # the outer/tenant param. Unreachable today (a branch calc-sort fails closed at sort/3's sort_clause
      # during branch build, before this callback) — a forward-compatible fail-closed for that future slice.
      Enum.any?(query.combination_of, &branch_has_expr_sort?/1) ->
        "expression-calculation sort on a combination branch is not supported"

      in_memory? and Enum.any?(query.sort, &match?({:expr, _, _}, &1)) ->
        "expression-calculation sort on an in-memory combination is not supported"

      in_memory? and not is_nil(query.expression) ->
        "a lazy filter expression on an in-memory combination is not supported"

      true ->
        nil
    end
  end

  defp branch_has_calculations?({_type, branch}), do: branch.calculations != []

  defp branch_has_expr_sort?({_type, branch}),
    do: Enum.any?(branch.sort, &match?({:expr, _, _}, &1))

  # A POSITIVE offset or any limit is MEANINGFUL per-branch paging → routes to the in-memory path
  # (combination_in_memory?/1). offset: 0 is Ash's spurious per-branch default (combination_queries always
  # sets it, deps/ash query.ex:4608) and is a no-op — treating it as paging would force EVERY combination
  # onto the in-memory path.
  defp branch_paged?({_type, branch}),
    do: branch.limit != nil or (is_integer(branch.offset) and branch.offset > 0)

  defp run_native_combination(conn, query, resource) do
    {cypher, params} = AshArcadic.Query.to_cypher(query)

    case Arcadic.query(conn, cypher, params) do
      {:ok, rows} ->
        {:ok, decode_records(resource, rows)}

      {:error, error} ->
        {:error,
         QueryFailed.exception(
           query: "ArcadeDB combination query",
           reason: redact_db_error(error)
         )}
    end
  end

  defp run_inmemory_combination(conn, query, resource) do
    pk = Ash.Resource.Info.primary_key(resource)
    domain = Ash.Resource.Info.domain(resource)

    case reduce_branch_results(query.combination_of, conn, query, resource) do
      {:ok, branch_results} ->
        records = Combination.combine(branch_results, pk)
        {:ok, apply_outer_modifiers(records, query, domain)}

      {:error, _} = err ->
        err
    end
  end

  defp reduce_branch_results(combinations, conn, query, resource) do
    combinations
    |> Enum.reduce_while({:ok, []}, fn {type, branch}, {:ok, acc} ->
      case run_branch(conn, branch, query, resource) do
        {:ok, records} -> {:cont, {:ok, [{type, records} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  # Push the OUTER filter into the branch so the combined set is outer-filtered — and, for a PAGED branch,
  # so the tenant filter applies BEFORE the branch's own SKIP/LIMIT (the reason combination_in_memory?/1
  # routes paged combinations here rather than to the native CALL-wrap, which filters after the union). The
  # set-algebra identity (A op B) ∩ F == (A∩F) op (B∩F) holds for same-resource deterministic stored-field
  # filters; a per-branch LIMIT is applied to the already-F-scoped branch, so it selects the tenant's top-k.
  # Re-key the branch's own $params so they never collide with the outer filter's $param<n> in this map.
  defp run_branch(conn, branch, query, resource) do
    {rk_filters, rk_params} = Combination.rekey_branch(branch.filters, branch.params, 0)

    branch2 = %{
      branch
      | filters: rk_filters ++ query.filters,
        params: Map.merge(rk_params, query.params)
    }

    {cypher, params} = AshArcadic.Query.to_cypher(branch2)

    case Arcadic.query(conn, cypher, params) do
      {:ok, rows} ->
        {:ok, decode_records(resource, rows)}

      {:error, error} ->
        {:error,
         QueryFailed.exception(
           query: "ArcadeDB combination query",
           reason: redact_db_error(error)
         )}
    end
  end

  # Outer sort/distinct via Ash's runtime helpers (ETS pattern, ets.ex:448-478 — note the module is
  # Ash.Actions.Sort; Ash.Sort delegates only runtime_sort, NOT runtime_distinct), then offset/limit.
  # We omit ETS's `maybe_not_distinct?: true` (it switches Ash.load's duplicate-PK handling from batched
  # to per-record): benign here because in-memory sort/distinct entries are guard-limited to stored
  # attributes already on the decoded records (Ash.load short-circuits, no re-read). It becomes load-bearing
  # only if a future slice admits calc/aggregate sorts on the in-memory path — add the flag then.
  defp apply_outer_modifiers(records, query, domain) do
    records
    |> distinct_and_sort(query, domain)
    |> apply_offset_limit(query.offset, query.limit)
  end

  defp distinct_and_sort(records, %{distinct: []} = query, domain),
    do: Sort.runtime_sort(records, query.sort, domain: domain, rekey?: false)

  defp distinct_and_sort(records, %{distinct_sort: []} = query, domain) do
    records
    |> Sort.runtime_sort(query.sort, domain: domain, rekey?: false)
    |> Sort.runtime_distinct(query.distinct, domain: domain, rekey?: false)
  end

  defp distinct_and_sort(records, query, domain) do
    records
    |> Sort.runtime_sort(query.distinct_sort, domain: domain, rekey?: false)
    |> Sort.runtime_distinct(query.distinct, domain: domain, rekey?: false)
    |> Sort.runtime_sort(query.sort, domain: domain, rekey?: false)
  end

  defp apply_offset_limit(records, offset, limit) do
    records = if offset, do: Enum.drop(records, offset), else: records
    if limit, do: Enum.take(records, limit), else: records
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

    # Hydrate each calc's expression ONCE up front — hydration is loop-invariant (depends only on
    # expression + resource, not the record), so hoisting it out of the per-record loop turns an
    # O(records × calcs) hydration into O(calcs).
    with {:ok, hydrated_calcs} <- hydrate_calcs(calcs, resource) do
      reduce_records(records, hydrated_calcs, resource, domain)
    end
  end

  defp reduce_records(records, hydrated_calcs, resource, domain) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case compute_calcs(record, hydrated_calcs, resource, domain) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  # Hydrate every calc expression once against the resource. Fail closed value-free on a hydration
  # error or raise (Rule 4). `Ash.Filter.hydrate_refs/2` is a compile-time-ish resolution, but rescue
  # anyway so no exception escapes the value-free wrapper.
  defp hydrate_calcs(calcs, resource) do
    calcs
    |> Enum.reduce_while({:ok, []}, fn {calc, expression}, {:ok, acc} ->
      case Ash.Filter.hydrate_refs(expression, %{resource: resource, public?: false}) do
        {:ok, hydrated} -> {:cont, {:ok, [{calc, hydrated} | acc]}}
        {:error, error} -> {:halt, {:error, calc_error(error)}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  rescue
    error -> {:error, calc_error(error)}
  end

  defp compute_calcs(record, hydrated_calcs, resource, domain) do
    Enum.reduce_while(hydrated_calcs, {:ok, record}, fn {calc, hydrated}, {:ok, record} ->
      case eval_hydrated_calc(record, calc, hydrated, resource, domain) do
        {:ok, value} -> {:cont, {:ok, put_calc(record, calc, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Eval a pre-hydrated calc over one record.
  # Returns {:ok, value} | {:error, %QueryFailed{}} (value-free); :unknown → {:ok, nil} (ETS parity).
  # Ash's runtime eval calls Elixir primitives directly (String.*, arithmetic) with no try/rescue, so
  # a RAISE (ArithmeticError on a/0, an argument error over raw non-sensitive :binary bytes, a
  # protocol/encoder error) would otherwise propagate UNCAUGHT past the value-free wrapper and could
  # carry the offending value in its message (Rule 4; `project_redaction_fail_path_exception_leak`).
  # Rescue to a value-free error — `calc_error/1`'s `redact_db_error/1` maps any non-Arcadic error to
  # the fixed "ArcadeDB error" reason, so the raised message never reaches Ash/logs.
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
  rescue
    error -> {:error, calc_error(error)}
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

  @impl true
  # Ash routes a combination_of query here (gated by can?(:combine) + can?({:combine, type})). For
  # :context, fail closed unless every branch resolved to the SAME non-nil tenant database (physical
  # isolation — a filter cannot scope :context). For :attribute, the tenant predicate is ALREADY in the
  # combined query.filters (handle_multitenancy runs on the outer combination query →
  # maybe_filter) and is applied by to_cypher / run_branch — the same posture as the flat
  # :attribute read path, so NO per-branch injection here. run_query dispatches native vs in-memory. The
  # combined query's outer filter/sort/distinct/limit/offset are applied by data_layer_query AFTER this
  # returns.
  def combination_of(combinations, resource, _domain) do
    with :ok <- validate_combination_chain(combinations),
         {:ok, database} <- combination_database(combinations, resource) do
      {:ok,
       %AshArcadic.Query{
         resource: resource,
         client: Info.client(resource),
         label: Info.label(resource),
         database: database,
         combination_of: combinations
       }}
    else
      {:error, reason} ->
        {:error, QueryFailed.exception(query: "ArcadeDB combination", reason: reason)}
    end
  end

  # The first branch must be `:base` and no later branch may be. Ash gates only the FIRST entry's type
  # (validate_combinations, deps/ash read.ex:1214), so a mid-chain `:base` is constructible from public
  # input. Reject it gracefully value-free HERE — a query error, not a render-time ArgumentError crash
  # (union_op/1, Combination.apply_op/4 keep those raises as unreachable defense-in-depth).
  defp validate_combination_chain([{:base, _} | rest]) do
    if Enum.any?(rest, fn {type, _branch} -> type == :base end),
      do: {:error, "combination_of: only the first branch may be :base"},
      else: :ok
  end

  defp validate_combination_chain(_),
    do: {:error, "combination_of: the first branch must be :base"}

  # :context — every branch must resolve to the SAME non-nil tenant database (set_tenant fired per
  # branch in combination_queries); a blank tenant (nil database) or branches spanning databases fail
  # closed value-free. Non-:context — carry the per-resource DSL default database (Info.database, nil →
  # client-conn default), mirroring the flat read path (query_database/1); :attribute tenant scoping
  # still rides query.filters, not the database.
  defp combination_database(combinations, resource) do
    if strategy(resource) == :context do
      combinations
      |> Enum.reduce_while({:ok, :unset}, &merge_branch_database/2)
      |> case do
        {:ok, :unset} -> {:ok, nil}
        other -> other
      end
    else
      {:ok, Info.database(resource)}
    end
  end

  # reduce_while over the :context branches, folding each branch database into the running one. A blank
  # (nil/"") database is a branch whose set_tenant never resolved a tenant → fail closed; a database that
  # differs from the running one → branches span databases → fail closed. :unset seeds the first branch.
  defp merge_branch_database({_type, branch}, {:ok, db}) do
    case {branch.database, db} do
      {blank, _} when blank in [nil, ""] ->
        {:halt, {:error, "multitenancy tenant required for :context combination"}}

      {d, :unset} ->
        {:cont, {:ok, d}}

      {d, d} ->
        {:cont, {:ok, d}}

      {_d, _other} ->
        {:halt, {:error, "combination branches span multiple tenant databases"}}
    end
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

    # The encode-gate covers EVERYTHING that rides the wire: $props (gated per attribute,
    # preserving the attribute-naming contract encode_gate_test pins) AND the atomic-fragment
    # $paramN literals (Expression binds an atomic-RHS literal RAW, so a poisoned non-UTF8
    # binary there would otherwise crash Jason.EncodeError at the wire with the bytes in the
    # message — AGENTS.md Rule 4).
    with {:ok, atomic_set, atomic_params} <- create_atomic_set(resource, changeset),
         :ok <- encode_gate(resource, props, CreateFailed),
         :ok <- encode_gate(resource, atomic_params, CreateFailed) do
      do_create(resource, changeset, props, atomic_set, atomic_params)
    else
      # Normalize the atomic-fold rejection (sibling parity with do_update_query_statement):
      # a raw %UnsupportedFilter{} from create_atomic_set is filter-flavored ("unsupported
      # filter operator") — misleading escaping a create callback. Value-free.
      {:error, %AshArcadic.Errors.UnsupportedFilter{}} ->
        {:error, CreateFailed.exception(resource: resource, reason: "unsupported atomic change")}

      # An encode_gate failure is already a value-free %CreateFailed{} — pass through.
      {:error, _} = err ->
        err
    end
  end

  # Atomic SET fragments for a create (changeset.create_atomics). Empty when none. ON CREATE atomics
  # reference incoming values only (no prior row); a self-ref `n.<field>` on a fresh node yields null.
  defp create_atomic_set(_resource, %{create_atomics: []}), do: {:ok, "", %{}}

  defp create_atomic_set(resource, changeset) do
    case Write.atomic_fragments(resource, changeset.create_atomics, %{}) do
      {:ok, [], _params} -> {:ok, "", %{}}
      {:ok, frags, params} -> {:ok, " SET " <> Enum.join(frags, ", "), params}
      {:error, _} = err -> err
    end
  end

  defp do_create(resource, changeset, props, atomic_set, atomic_params) do
    case write_conn(resource, changeset) do
      {:ok, conn} ->
        label = validated_label(resource)
        cypher = "CREATE (n:#{label} $props)#{atomic_set} RETURN n"
        params = Map.merge(atomic_params, %{"props" => props})

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
         bulk_upsert?: Map.get(options, :upsert?, false) == true,
         result: Telemetry.result_tag(result),
         in_transaction?: AshArcadic.Transaction.in_transaction?()
       }}
    end)
  end

  # An empty batch writes nothing (no scoping surface) → :ok without touching the DB.
  defp do_bulk_create(_resource, [], _options), do: :ok

  # Bulk UPSERT via UNWIND MERGE — the ArcadeDB divergence from the AGE sibling (which
  # BANS MERGE). Ash routes a bulk `upsert? true` action here with `options.upsert? ==
  # true`. `upsert_identity_keys/2` appends the `:attribute` discriminator to the merge
  # key so a cross-tenant PK collision MATCHes nothing and CREATEs its own tenant-local
  # row (D4 — never hijacks another tenant's row); `:context` isolates by database and
  # needs no discriminator.
  defp do_bulk_create(resource, entries, %{upsert?: true} = options) do
    identity_keys =
      upsert_identity_keys(
        resource,
        options.upsert_keys || Ash.Resource.Info.primary_key(resource)
      )

    if identity_keys == [] do
      # Fail closed: an empty identity would emit `MERGE (n:L {})`, matching ANY node
      # (a catastrophic ON MATCH clobber). Sibling parity with do_upsert/3.
      {:error,
       CreateFailed.exception(
         resource: resource,
         reason: "bulk upsert requires a non-empty identity (no primary key or upsert keys)"
       )}
    else
      run_bulk_upsert(resource, entries, options, identity_keys)
    end
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
    # Ash batches by tenant AND groups by changeset.create_atomics (create/bulk.ex), so all
    # changesets in one batch share one database AND one atomic-set — resolve/fold off the first.
    # Advertising {:atomic, :create} makes Ash push create_atomics HERE too (V8 fail-open surface):
    # fold the shared create-phase atomic into the UNWIND CREATE, or the atomic change is silently
    # dropped on bulk create. The atomic $paramN literals ride the wire, so encode-gate them too.
    with {:ok, atomic_set, atomic_params} <- bulk_create_atomic_set(resource, entries),
         :ok <- encode_gate(resource, atomic_params, CreateFailed),
         {:ok, conn} <- bulk_conn(resource, entries) do
      label = validated_label(resource)
      rows = Enum.map(entries, fn {_changeset, props} -> props end)
      return_records? = Map.get(options, :return_records?, false)
      cypher = "UNWIND $rows AS row CREATE (n:#{label}) SET n += row#{atomic_set} RETURN n"

      conn
      |> Arcadic.command(cypher, Map.merge(atomic_params, %{"rows" => rows}))
      |> decode_bulk_result(resource, entries, return_records?)
    else
      # A sensitive/non-stored/discriminator atomic target normalizes to value-free CreateFailed
      # (sibling parity with do_create); an encode_gate failure is already %CreateFailed{}.
      {:error, %AshArcadic.Errors.UnsupportedFilter{}} ->
        {:error, CreateFailed.exception(resource: resource, reason: "unsupported atomic change")}

      {:error, reason} when is_atom(reason) ->
        {:error, CreateFailed.exception(resource: resource, reason: conn_error_reason(reason))}

      {:error, _} = err ->
        err
    end
  end

  # One UNWIND MERGE for the whole batch. Per row we ship: the identity values TOP-LEVEL
  # (read by the merge pattern as `r.<key>` — the P4-proven bulk form, distinct from the
  # single-row `$mk_<key>` bound form), plus the namespaced container `"__arcadic_all__"` (the full
  # property map → ON CREATE `n += r.__arcadic_all__`, seeds the force-set discriminator from all_props
  # → D4 tenant-scoped merge) and `"__arcadic_set__"` (the ON MATCH subset → `n += r.__arcadic_set__`;
  # leading-underscore so a PK/identity literally named `:set`/`:all` can't collide). BOTH atomic phases fold (V8
  # parity with run_upsert): the representative's `create_atomics` → ON CREATE SET suffix,
  # its `atomics` → ON MATCH SET suffix — Ash groups a bulk batch by `{atomics,
  # create_atomics, filter}` (create/bulk.ex:1233), so all entries share the head's
  # atomics/create_atomics (same assumption bulk_create_atomic_set makes). The atomic
  # $paramN literals are shared across every unwound row and ride the wire, so encode-gate
  # them too; a sensitive/non-stored/discriminator atomic TARGET fails closed value-free
  # (upsert_atomic_set → Write.atomic_fragments guards the LHS on BOTH phases, spec §7.1).
  defp run_bulk_upsert(resource, [{rep_changeset, _} | _] = entries, options, identity_keys) do
    return_records? = Map.get(options, :return_records?, false)
    identity_key_strings = Enum.map(identity_keys, &Atom.to_string/1)

    rows =
      Enum.map(entries, fn {changeset, all_props} ->
        # Sibling parity with do_upsert/3: the ON MATCH subset is Ash's canonical
        # `set_on_upsert/2` (honors the changeset's configured upsert_fields context AND
        # folds update-defaults) minus identity_keys+skip — NOT a raw options.upsert_fields
        # filter over changeset.attributes, which would diverge. Rejecting identity_keys
        # keeps the discriminator OUT of ON MATCH (D3 — never SET the disc, a tenant-hop).
        set = upsert_set_map(resource, changeset, identity_keys)

        # Container keys are namespaced (leading underscore) so they can NEVER collide with a
        # same-named identity/PK carried TOP-LEVEL: `Arcadic.Identifier` requires a leading LETTER,
        # so a field named `:set`/`:all` stays top-level while the containers ride `__arcadic_*__`.
        all_props
        |> Map.take(identity_key_strings)
        |> Map.merge(%{"__arcadic_all__" => all_props, "__arcadic_set__" => set})
      end)

    # Fold both atomic phases off the representative, threading one shared $paramN seed so
    # ON CREATE and ON MATCH params never collide (exactly run_upsert's ordering). Then gate
    # every wire value before any DB touch: `%{"rows" => rows}` (identity + all + set) AND
    # the atomic params (bound RAW by Expression — a poisoned non-UTF8 literal there would
    # otherwise crash Jason.EncodeError with the bytes in the message, Rule 4).
    with {:ok, match_set, params} <- upsert_atomic_set(resource, rep_changeset.atomics, %{}),
         {:ok, create_set, params} <-
           upsert_atomic_set(resource, rep_changeset.create_atomics, params),
         :ok <- encode_gate(resource, %{"rows" => rows}, CreateFailed),
         :ok <- encode_gate(resource, params, CreateFailed),
         {:ok, conn} <- bulk_conn(resource, entries) do
      label = validated_label(resource)
      merge_pattern = bulk_merge_pattern(identity_keys)

      cypher =
        "UNWIND $rows AS r MERGE (n:#{label} #{merge_pattern}) " <>
          "ON CREATE SET n += r.__arcadic_all__#{create_set} ON MATCH SET n += r.__arcadic_set__#{match_set} RETURN n"

      conn
      |> Arcadic.command(cypher, Map.merge(params, %{"rows" => rows}))
      |> decode_bulk_result(resource, entries, return_records?)
    else
      # A sensitive/non-stored/discriminator atomic target normalizes to value-free
      # CreateFailed (sibling parity with do_upsert); an encode_gate failure is already
      # %CreateFailed{}; a conn error is an atom.
      {:error, %AshArcadic.Errors.UnsupportedFilter{}} ->
        {:error, CreateFailed.exception(resource: resource, reason: "unsupported atomic change")}

      {:error, reason} when is_atom(reason) ->
        {:error, CreateFailed.exception(resource: resource, reason: conn_error_reason(reason))}

      {:error, _} = err ->
        err
    end
  end

  # The bulk MERGE identity pattern `{k1: r.k1, ...}` — each key validated as an identifier
  # (only the field NAME is interpolated), each value read TOP-LEVEL off the unwound `r`
  # (NEVER interpolated). Composite identities supported. Distinct from the single-row
  # `merge_identity/3`'s `$mk_<key>` bound form: the values ride inside `$rows`.
  defp bulk_merge_pattern(identity_keys) do
    "{" <>
      Enum.map_join(identity_keys, ", ", fn key ->
        k = key |> to_string() |> AshArcadic.Identifier.validate!()
        "#{k}: r.#{k}"
      end) <> "}"
  end

  # Shared create-phase atomic SET fragments for a bulk create — Ash groups by create_atomics so all
  # entries share the representative from the first. Empty ("") when there are no create atomics; else
  # a `, n.<f> = <cypher>` continuation of the existing `SET n += row`, applied to every unwound row.
  defp bulk_create_atomic_set(_resource, [{%{create_atomics: []}, _props} | _]),
    do: {:ok, "", %{}}

  defp bulk_create_atomic_set(resource, [{changeset, _props} | _]) do
    case Write.atomic_fragments(resource, changeset.create_atomics, %{}) do
      {:ok, [], _params} -> {:ok, "", %{}}
      {:ok, frags, params} -> {:ok, ", " <> Enum.join(frags, ", "), params}
      {:error, _} = err -> err
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

    # Everything that rides the wire is gated BEFORE any DB touch: $props/$on_match per
    # attribute (props already carries the identity values too; attribute-naming contract
    # preserved) AND the atomic $paramN literals — an atomic-RHS literal is bound RAW by
    # Expression, so a poisoned non-UTF8 binary there would otherwise crash Jason.EncodeError
    # with the bytes in the message (Rule 4). BOTH atomic phases fold (V8): changeset.atomics →
    # ON MATCH SET (`atomic_update`, references the matched row), changeset.create_atomics → ON
    # CREATE SET (`atomic_set`, the insert branch — dropping it silently loses the atomic on an
    # upsert-insert). The two share one $paramN accumulator (threaded) so their params never collide.
    with {:ok, match_set, params} <- upsert_atomic_set(resource, changeset.atomics, %{}),
         {:ok, create_set, params} <-
           upsert_atomic_set(resource, changeset.create_atomics, params),
         :ok <- encode_gate(resource, Map.merge(props, on_match), CreateFailed),
         :ok <- encode_gate(resource, params, CreateFailed) do
      run_upsert(
        resource,
        changeset,
        identity_keys,
        props,
        on_match,
        match_set,
        create_set,
        params
      )
    else
      # Normalize the atomic-fold rejection (sibling parity with do_update_query_statement):
      # a raw %UnsupportedFilter{} from upsert_atomic_set is filter-flavored — misleading
      # escaping an upsert callback. Value-free.
      {:error, %AshArcadic.Errors.UnsupportedFilter{}} ->
        {:error, CreateFailed.exception(resource: resource, reason: "unsupported atomic change")}

      # An encode_gate failure is already a value-free %CreateFailed{} — pass through.
      {:error, _} = err ->
        err
    end
  end

  # Atomic SET-clause suffix ("" or ", n.<f> = <cypher>, …") for a list of atomics, threading
  # `seed_params` so the ON MATCH and ON CREATE folds never collide on $paramN. Shared by both
  # upsert branches; the suffix continues the existing `SET n += $on_match`/`$props`.
  defp upsert_atomic_set(_resource, [], seed_params), do: {:ok, "", seed_params}

  defp upsert_atomic_set(resource, atomics, seed_params) do
    case Write.atomic_fragments(resource, atomics, seed_params) do
      {:ok, [], params} -> {:ok, "", params}
      {:ok, frags, params} -> {:ok, ", " <> Enum.join(frags, ", "), params}
      {:error, _} = err -> err
    end
  end

  defp run_upsert(
         resource,
         changeset,
         identity_keys,
         props,
         on_match,
         match_set,
         create_set,
         params
       ) do
    case write_conn(resource, changeset) do
      {:ok, conn} ->
        label = validated_label(resource)
        {match_pattern, match_params} = merge_identity(resource, changeset, identity_keys)

        cypher =
          "MERGE (n:#{label} #{match_pattern}) " <>
            "ON CREATE SET n += $props#{create_set} ON MATCH SET n += $on_match#{match_set} RETURN n"

        params =
          match_params
          |> Map.merge(%{"props" => props, "on_match" => on_match})
          |> Map.merge(params)

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
  def update_query(%AshArcadic.Query{} = query, changeset, resource, opts) do
    Telemetry.span(:update_query, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_update_query(query, changeset, resource, opts)

      {result,
       %{
         tenant?: not is_nil(query.tenant),
         matched: matched_count(result),
         result: Telemetry.result_tag(result),
         in_transaction?: AshArcadic.Transaction.in_transaction?()
       }}
    end)
  end

  defp do_update_query(query, changeset, resource, opts) do
    cond do
      not bulk_write_scopeable?(query) ->
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason: "bulk update does not support limit/offset/combination (use strategy: :stream)"
         )}

      Map.get(opts, :calculations, []) != [] ->
        # Ash passes {:run_after_batch, where} gating calcs so conditional after_batch
        # hooks (`change …, where: [...]`) fire per-record; a one-statement SET cannot
        # evaluate them, and ignoring them silently SKIPS the hooks. Fail closed.
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason:
             "bulk update with conditional after-batch hooks is not supported (use strategy: :stream)"
         )}

      true ->
        do_update_query_statement(query, changeset, resource, opts)
    end
  end

  defp do_update_query_statement(query, changeset, resource, opts) do
    {where, where_params} = AshArcadic.Query.where_and_params(query)

    with {:ok, set_clause, params} <- Write.build_set(resource, changeset, where_params),
         # Gate EVERY bound value — the $paramN atomic-RHS/WHERE scalars AND the nested
         # "static" map (Jason.encode recurses into it). A poisoned binary in ANY of them
         # fails closed value-free here instead of leaking bytes via Jason.EncodeError.
         :ok <- encode_gate(resource, params, UpdateFailed),
         {:ok, conn} <- query_write_conn(query, resource) do
      label = validated_label(resource)
      return? = Map.get(opts, :return_records?, false)
      cypher = "MATCH (n:#{label}) #{where} SET #{set_clause}#{return_suffix(return?)}"

      decode_query_write(resource, return?, Arcadic.command(conn, cypher, params))
    else
      {:error, %AshArcadic.Errors.UnsupportedFilter{}} ->
        {:error,
         UpdateFailed.exception(resource: resource, reason: "unsupported atomic/static change")}

      {:error, reason} when is_atom(reason) ->
        {:error, UpdateFailed.exception(resource: resource, reason: conn_error_reason(reason))}

      {:error, %{} = err} ->
        {:error, err}
    end
  end

  # A query-scoped bulk write compiles to ONE `MATCH … SET/DELETE` over the WHERE — it cannot honor
  # a limit/offset (no per-row ordering semantics) or a combination. offset: 0 is Ash's spurious
  # default (query.ex build_skip treats it as absent) → NOT paging. Reject the rest fail-closed so a
  # paged bulk write is a loud value-free error, never a silent unscoped mutation.
  defp bulk_write_scopeable?(%AshArcadic.Query{} = query) do
    is_nil(query.limit) and query.offset in [nil, 0] and query.combination_of == []
  end

  # RETURN n only when Ash wants the records back; otherwise the statement mutates and returns :ok.
  defp return_suffix(true), do: " RETURN n"
  defp return_suffix(false), do: ""

  # return_records? false → :ok. true → decode each flat vertex. An EMPTY match is a valid no-op
  # ({:ok, []}), NEVER StaleRecord — bulk semantics differ from the single-row pk-scoped write
  # (spec D2). A row-count mismatch is impossible here (one statement, N matched rows returned).
  defp decode_query_write(_resource, false, {:ok, _rows}), do: :ok

  defp decode_query_write(resource, true, {:ok, rows}) do
    attribute_map = Info.attribute_map(resource)
    attribute_types = Info.attribute_types(resource)

    records =
      Enum.map(rows, fn row ->
        record = struct(resource, Cast.row_to_attrs(row, attribute_map, attribute_types))
        %{record | __meta__: %Metadata{state: :loaded, schema: resource}}
      end)

    {:ok, records}
  end

  defp decode_query_write(resource, _return?, {:error, error}) do
    {:error, UpdateFailed.exception(resource: resource, reason: redact_db_error(error))}
  end

  # matched count for telemetry: the returned-row count when records are returned, else nil (a
  # RETURN-less mutation reports no count — do not mis-report 0 matched). Value-free (an integer).
  defp matched_count({:ok, records}) when is_list(records), do: length(records)
  defp matched_count(_), do: nil

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

  @impl true
  def destroy_query(%AshArcadic.Query{} = query, _changeset, resource, opts) do
    Telemetry.span(:destroy_query, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_destroy_query(query, resource, opts)

      {result,
       %{
         tenant?: not is_nil(query.tenant),
         matched: matched_count(result),
         result: Telemetry.result_tag(result),
         in_transaction?: AshArcadic.Transaction.in_transaction?()
       }}
    end)
  end

  defp do_destroy_query(query, resource, opts) do
    cond do
      not bulk_write_scopeable?(query) ->
        {:error,
         QueryFailed.exception(
           query: "ArcadeDB bulk delete",
           reason:
             "bulk destroy does not support limit/offset/combination (use strategy: :stream)"
         )}

      Map.get(opts, :calculations, []) != [] ->
        # Symmetric with do_update_query: Ash passes {:run_after_batch, where} gating calcs
        # (destroy/bulk.ex hooks_and_calcs_for_update_query) so conditional after_batch hooks
        # fire per-record; a one-statement DELETE cannot evaluate them, and ignoring them
        # silently SKIPS the hooks. Fail closed.
        {:error,
         QueryFailed.exception(
           query: "ArcadeDB bulk delete",
           reason:
             "bulk destroy with conditional after-batch hooks is not supported (use strategy: :stream)"
         )}

      true ->
        do_destroy_query_statement(query, resource, opts)
    end
  end

  defp do_destroy_query_statement(query, resource, opts) do
    {where, params} = AshArcadic.Query.where_and_params(query)

    # Gate the WHERE $paramN scalars before the wire — SYMMETRIC with update_query (whose merged
    # params are gated at do_update_query_statement). Ash's :string cast accepts a non-UTF8 binary,
    # so a poisoned filter literal reaches params un-gated and would otherwise crash Jason.EncodeError
    # with the bytes in the message (Rule 4). Value-free QueryFailed, before any conn/DELETE.
    with :ok <- destroy_where_encode_gate(params),
         {:ok, conn} <- query_write_conn(query, resource) do
      label = validated_label(resource)
      return? = Map.get(opts, :return_records?, false)

      # P3: post-delete `RETURN n` yields no attributes; capture properties(n) BEFORE the
      # DETACH DELETE when records are wanted. return_records? false → no RETURN, mutate only.
      cypher =
        if return? do
          "MATCH (n:#{label}) #{where} WITH n, properties(n) AS p DETACH DELETE n RETURN p"
        else
          "MATCH (n:#{label}) #{where} DETACH DELETE n"
        end

      decode_destroy_query(resource, return?, Arcadic.command(conn, cypher, params))
    else
      # The encode gate already returns a value-free %QueryFailed{} — pass it through.
      {:error, %QueryFailed{}} = err ->
        err

      {:error, reason} ->
        {:error,
         QueryFailed.exception(query: "ArcadeDB bulk delete", reason: conn_error_reason(reason))}
    end
  end

  # Value-free encode gate for the destroy WHERE params — QueryFailed-flavored (encode_gate/3 is
  # keyed on `resource:`, which QueryFailed's `[:query, :reason]` fields do not carry). Names only the
  # $paramN KEY (structural), never the offending value.
  defp destroy_where_encode_gate(params) do
    case encode_check(params) do
      :ok ->
        :ok

      {:error, key} ->
        {:error,
         QueryFailed.exception(query: "ArcadeDB bulk delete", reason: encode_error_reason(key))}
    end
  end

  # return_records? false → :ok. true → decode each captured pre-delete property map. An empty
  # match is a valid no-op ({:ok, []}), NEVER StaleRecord (spec D2). `p` is the properties(n)
  # map (user props only) — Cast.row_to_attrs maps the declared attributes from it.
  defp decode_destroy_query(_resource, false, {:ok, _rows}), do: :ok

  defp decode_destroy_query(resource, true, {:ok, rows}) do
    attribute_map = Info.attribute_map(resource)
    attribute_types = Info.attribute_types(resource)

    records =
      Enum.map(rows, fn %{"p" => props} ->
        record = struct(resource, Cast.row_to_attrs(props, attribute_map, attribute_types))
        %{record | __meta__: %Metadata{state: :deleted, schema: resource}}
      end)

    {:ok, records}
  end

  defp decode_destroy_query(_resource, _return?, {:error, error}) do
    {:error, QueryFailed.exception(query: "ArcadeDB bulk delete", reason: redact_db_error(error))}
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
            {:ok, and_compose(base_where, clause), params}

          {:error, _} = err ->
            err
        end
    end
  end

  # AND-joins two bare WHERE clauses. An empty base (update_many's non-multitenant scope keeps the PK
  # in the MATCH pattern, so its base clause is "") yields the filter clause alone — never a malformed
  # leading " AND ". update/2 & destroy/2 always pass a non-empty PK clause, so their behavior is
  # unchanged.
  defp and_compose("", clause), do: clause
  defp and_compose(base_where, clause), do: base_where <> " AND " <> clause

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

  @impl true
  # Heterogeneous per-record bulk update. Ash (`Ash.update_many/4`) groups the changesets by
  # {atomics, filter} and hands each group here; a group shares one set of atomics AND one filter (the
  # group key), so `rep.atomics` folds into the statement ONCE and `rep.filter` composes into the
  # WHERE ONCE (see run_update_many), while each row's OWN static changes ride the per-row `$rows`
  # UNWIND. (A batch of static-only changes — e.g. `%{name: "X"}` per row — shares group key {[], nil}
  # and forms ONE multi-row group exercising `n += r.__arcadic_set__` across every row.) The `:attribute`
  # discriminator is injected from `opts.tenant` (never row data) as a WHERE predicate; `:context`
  # targets the tenant database and fails closed on a blank tenant. A row whose PK/filter matches
  # nothing is simply absent from the returned records (spec D2 bulk semantics) — never a data-layer
  # error.
  def update_many(resource, changesets, opts) do
    entries = Enum.to_list(changesets)

    Telemetry.span(:update_many, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result = do_update_many(resource, entries, opts)

      {result,
       %{
         batch_size: length(entries),
         tenant?: tenant_present?(opts),
         matched: matched_count(result),
         result: Telemetry.result_tag(result),
         in_transaction?: AshArcadic.Transaction.in_transaction?()
       }}
    end)
  end

  # An empty group writes nothing.
  defp do_update_many(_resource, [], _opts), do: {:ok, []}

  defp do_update_many(resource, [rep | _] = entries, _opts) do
    pk = Ash.Resource.Info.primary_key(resource)
    types = Info.attribute_types(resource)

    disc =
      if strategy(resource) == :attribute, do: Ash.Resource.Info.multitenancy_attribute(resource)

    rows =
      Enum.map(entries, fn changeset ->
        # The per-record change map rides a namespaced container (leading underscore) so it can never
        # collide with a same-named PK carried TOP-LEVEL (a PK named `:set` — `Arcadic.Identifier`
        # requires a leading letter, so the container `__arcadic_set__` is unreachable as a field name).
        Map.put(
          pk_row_key(changeset, pk, types),
          "__arcadic_set__",
          changeset_to_properties(resource, changeset)
        )
      end)

    # Reject a static write to the multitenancy discriminator (a tenant-hop) up front — a key-presence
    # check, NOT an encode gate. JSON-encodability of every wire value (row `set` maps, atomic/filter
    # $paramN, $tenant) is gated ONCE on the final params in run_update_many, symmetric with
    # update_query's single encode_gate (AGENTS.md Rule 4).
    if disc && Enum.any?(rows, &Map.has_key?(&1["__arcadic_set__"], Atom.to_string(disc))) do
      {:error,
       UpdateFailed.exception(
         resource: resource,
         reason: "cannot set the multitenancy discriminator"
       )}
    else
      run_update_many(resource, rep, rows, pk)
    end
  end

  defp run_update_many(resource, rep, rows, pk) do
    # The ToTenant-NORMALIZED tenant, NOT the raw `opts.tenant` (data_layer_opts carries opts[:tenant]
    # verbatim — deps/ash update_many.ex). Ash stores the `:attribute` discriminator as
    # parse_attribute(changeset.to_tenant) (create.ex) and resolves the `:context` write database from
    # changeset.to_tenant, so update_many MUST scope by the SAME normalized value the single-row and
    # bulk-upsert paths use (both key off changeset.to_tenant) — else a custom Ash.ToTenant maps
    # opts.tenant to a discriminator/database that never matches the stored rows. Byte-identical to
    # opts.tenant for a plain String/Integer/Atom tenant (their default ToTenant is identity).
    tenant = rep.to_tenant

    # write_conn_for_tenant/2 is the CANONICAL resource+tenant → write-conn resolver (the single-row
    # write_conn/2 is a thin changeset adapter over it, also keyed on changeset.to_tenant). update_many
    # reuses it — no third parallel resolver — with the same :context blank→:tenant_required /
    # present→tenant-db / non-:context→base behavior.
    with {:ok, atomic_frags, atomic_params} <-
           Write.atomic_fragments(resource, rep.atomics, %{}),
         {:ok, conn} <- write_conn_for_tenant(resource, tenant) do
      {match_pattern, tenant_clause, tenant_params} = update_many_scope(resource, pk, tenant)
      seed = Map.merge(atomic_params, Map.merge(tenant_params, %{"rows" => rows}))
      label = validated_label(resource)
      set_clause = update_many_set_clause(atomic_frags)

      # AND-compose the group's shared changeset.filter (rep.filter — atomic validation / optimistic
      # lock / policy scoping) onto the tenant clause, SYMMETRIC with update/2 & destroy/2's
      # changeset_where. The group key is {atomics, filter}, so rep.filter is shared across every row
      # in `rows` → apply it ONCE. changeset_where threads the filter's $paramN off `seed` (skipping
      # the atomic/tenant/rows keys) and FAILS CLOSED on an untranslatable filter — a filtered-out row
      # is simply absent from RETURN n (Ash reports it StaleRecord), never a silent over-update.
      case changeset_where(rep, tenant_clause, seed) do
        {:ok, where_clause, params} ->
          cypher =
            "UNWIND $rows AS r MATCH (n:#{label} #{match_pattern})#{where_keyword(where_clause)} " <>
              "SET #{set_clause} RETURN n"

          emit_update_many(resource, conn, cypher, params)

        {:error, _} ->
          {:error,
           UpdateFailed.exception(
             resource: resource,
             reason: "unsupported scoping filter on bulk update"
           )}
      end
    else
      {:error, %UnsupportedFilter{}} ->
        {:error, UpdateFailed.exception(resource: resource, reason: "unsupported atomic change")}

      {:error, reason} when is_atom(reason) ->
        {:error, UpdateFailed.exception(resource: resource, reason: conn_error_reason(reason))}
    end
  end

  # The per-row PK MATCH pattern (`{id: r.id, …}`) + the BARE tenant scope clause (composed into the
  # WHERE by changeset_where alongside rep.filter). `:attribute` injects the discriminator predicate
  # from `opts.tenant` (parsed to the stored value, NEVER read off row data) so every matched node is
  # tenant-scoped; `:context` needs no predicate (physical-database isolation via write_conn).
  # PK/discriminator NAMES are identifier-validated; the tenant value rides `$tenant` bound.
  defp update_many_scope(resource, pk, tenant) do
    pattern =
      "{" <>
        Enum.map_join(pk, ", ", fn k ->
          kk = k |> to_string() |> AshArcadic.Identifier.validate!()
          "#{kk}: r.#{kk}"
        end) <> "}"

    case strategy(resource) do
      :attribute ->
        attr = Ash.Resource.Info.multitenancy_attribute(resource)
        {m, f, a} = Ash.Resource.Info.multitenancy_parse_attribute(resource)
        value = apply(m, f, [tenant | a])
        attr_name = attr |> to_string() |> AshArcadic.Identifier.validate!()
        {pattern, "n.#{attr_name} = $tenant", %{"tenant" => value}}

      _ ->
        {pattern, "", %{}}
    end
  end

  # [{"<pk_field>" => serialized_original_value}] — the identity of each row. get_data/2 (the STORED
  # key), never the pending value: a writable PK in `accept` would make the MATCH miss the row.
  defp pk_row_key(changeset, pk, types) do
    Map.new(pk, fn field ->
      value = Ash.Changeset.get_data(changeset, field)
      {Atom.to_string(field), Cast.serialize_value(value, Map.get(types, field))}
    end)
  end

  # The shared atomic fold prepends `n += r.__arcadic_set__` (the namespaced per-row static merge) to
  # the group's atomic SET fragments. Empty atomics → a pure static per-row merge.
  defp update_many_set_clause([]), do: "n += r.__arcadic_set__"

  defp update_many_set_clause(atomic_frags),
    do: Enum.join(["n += r.__arcadic_set__" | atomic_frags], ", ")

  # Prefixes the combined scope clause with the WHERE keyword, or "" when there is no scope (PK-only
  # match via the MATCH pattern). Keeps run_update_many's nesting within credo's depth budget.
  defp where_keyword(""), do: ""
  defp where_keyword(clause), do: " WHERE #{clause}"

  # Final wire step: encode-gate the COMPLETE params map ONCE (the `rows` set maps — Jason recurses —
  # plus the atomic/filter `$paramN` scalars and the `$tenant` value), then command. SYMMETRIC with
  # update_query's single encode_gate: any un-encodable value fails closed value-free naming only the
  # $param KEY, before the wire, never a Jason.EncodeError leaking bytes (AGENTS.md Rule 4).
  defp emit_update_many(resource, conn, cypher, params) do
    case encode_gate(resource, params, UpdateFailed) do
      :ok ->
        resource
        |> decode_query_write(true, Arcadic.command(conn, cypher, params))
        |> guard_update_many_cardinality(resource)

      {:error, _} = err ->
        err
    end
  end

  # ArcadeDB enforces NO primary-key uniqueness, so the per-row `MATCH (n {id: r.id})` can match 2+
  # nodes for ONE changeset PK (a duplicate row in the graph — a raw write, or the MERGE upsert
  # concurrency race). Fail CLOSED value-free — mirroring the single-row decode_update_result guard —
  # rather than silently updating (and returning) multiple rows for one primary key. A PK ABSENT from
  # the returned records (0 matches) is a legitimate bulk no-op (spec D2); only >1 fails. The
  # frequency map is value-free (PK-field NAMES + integer counts only, never a value or the Cypher).
  defp guard_update_many_cardinality({:ok, records} = ok, resource) do
    pk = Ash.Resource.Info.primary_key(resource)

    duplicated? =
      records
      |> Enum.frequencies_by(fn record -> Enum.map(pk, &Map.get(record, &1)) end)
      |> Enum.any?(fn {_key, count} -> count > 1 end)

    if duplicated? do
      {:error,
       UpdateFailed.exception(
         resource: resource,
         reason:
           "bulk update matched multiple rows for one primary key (duplicate rows in graph?)"
       )}
    else
      ok
    end
  end

  defp guard_update_many_cardinality({:error, _} = err, _resource), do: err

  defp tenant_present?(opts), do: not is_nil(Map.get(opts, :tenant))

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
  # Resolves the ArcadeDB database name for a WRITE from a changeset — a thin adapter over
  # write_database_for_tenant/2 keyed on `changeset.to_tenant`.
  @spec write_database(Ash.Resource.t(), Ash.Changeset.t()) ::
          {:ok, String.t() | nil} | {:error, :tenant_required}
  def write_database(resource, changeset),
    do: write_database_for_tenant(resource, Map.get(changeset, :to_tenant))

  # The database name for a WRITE, keyed on the raw tenant (update_many has `opts.tenant`, not a
  # changeset). Gated on the multitenancy STRATEGY, not on tenant presence (populated for :attribute
  # too). For :context a nil/blank tenant FAILS CLOSED — there is no global database, and falling
  # through to the base database would be a silent cross-tenant write.
  @spec write_database_for_tenant(Ash.Resource.t(), term()) ::
          {:ok, String.t() | nil} | {:error, :tenant_required}
  defp write_database_for_tenant(resource, tenant) do
    if strategy(resource) == :context do
      case tenant do
        blank when blank in [nil, ""] -> {:error, :tenant_required}
        t -> {:ok, AshArcadic.Multitenancy.database_name(resource, t)}
      end
    else
      {:ok, Info.database(resource)}
    end
  end

  @doc false
  # The write connection for a changeset — a thin adapter over write_conn_for_tenant/2 keyed on
  # `changeset.to_tenant`.
  @spec write_conn(Ash.Resource.t(), Ash.Changeset.t()) ::
          {:ok, Arcadic.Conn.t()}
          | {:error, :tenant_required | :cross_database_transaction | :transaction_begin_failed}
  def write_conn(resource, changeset),
    do: write_conn_for_tenant(resource, Map.get(changeset, :to_tenant))

  # The write connection keyed on the raw tenant, fail-closed on a blank :context tenant. The
  # CANONICAL resource+tenant → write-conn resolver, shared by write_conn/2 (single-row) and
  # update_many/3. Routes the database-targeted base conn through resolve_conn/2, an EXACT passthrough
  # outside a transaction that folds in the cross-database session guard inside one.
  @spec write_conn_for_tenant(Ash.Resource.t(), term()) ::
          {:ok, Arcadic.Conn.t()}
          | {:error, :tenant_required | :cross_database_transaction | :transaction_begin_failed}
  defp write_conn_for_tenant(resource, tenant) do
    case write_database_for_tenant(resource, tenant) do
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
  # The read connection for a query — resolve_query_conn/3 in :read mode. :context REQUIRES a
  # database resolved by set_tenant/3; a nil/blank database means set_tenant never fired (blank
  # tenant) → fail closed rather than reading the base database (a silent cross-tenant read).
  @spec read_conn(AshArcadic.Query.t(), Ash.Resource.t()) ::
          {:ok, Arcadic.Conn.t()}
          | {:error, :tenant_required | :cross_database_transaction | :transaction_begin_failed}
  def read_conn(%AshArcadic.Query{} = query, resource),
    do: resolve_query_conn(query, resource, :read)

  @doc false
  # Write connection for a query-scoped bulk write (update_query/destroy_query), resolved from the
  # DATA-LAYER QUERY (not a changeset) — resolve_query_conn/3 in :write mode (session write-first /
  # cross-database guard inside a transaction). Same fail-closed :context posture as read_conn/2;
  # :attribute uses the base database (its tenant scoping is the discriminator predicate already
  # ANDed into query.filters).
  @spec query_write_conn(AshArcadic.Query.t(), Ash.Resource.t()) ::
          {:ok, Arcadic.Conn.t()}
          | {:error, :tenant_required | :cross_database_transaction | :transaction_begin_failed}
  def query_write_conn(%AshArcadic.Query{} = query, resource),
    do: resolve_query_conn(query, resource, :write)

  # Shared query-conn resolver — read and write differ ONLY in the resolve_conn/2 mode atom. :context
  # fails closed on a blank tenant (nil/"" database) — never the base DB (a silent cross-tenant op);
  # a resolved :context database re-targets the conn; :attribute/non-multitenant use the base DB (nil
  # database) or the query's database, scoped by the WHERE predicate. resolve_conn/2 is exact
  # passthrough outside a transaction, session-reuse / cross-database-guarded inside one.
  @spec resolve_query_conn(AshArcadic.Query.t(), Ash.Resource.t(), :read | :write) ::
          {:ok, Arcadic.Conn.t()}
          | {:error, :tenant_required | :cross_database_transaction | :transaction_begin_failed}
  defp resolve_query_conn(%AshArcadic.Query{} = query, resource, mode) do
    case {strategy(resource), query.database} do
      {:context, blank} when blank in [nil, ""] ->
        {:error, :tenant_required}

      {_strategy, nil} ->
        AshArcadic.Transaction.resolve_conn(conn_for(resource), mode)

      {_strategy, database} ->
        AshArcadic.Transaction.resolve_conn(
          Arcadic.with_database(conn_for(resource), database),
          mode
        )
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

  defp combination_strategy([]), do: nil

  # Must key on the SAME predicate as the run_combination dispatch (combination_in_memory?/1) — a paged
  # union-family combination is union-family (native?/1 true) but EXECUTES in-memory, so keying on native?/1
  # would mislabel it :native.
  defp combination_strategy(combos),
    do: if(combination_in_memory?(combos), do: :in_memory, else: :native)

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
