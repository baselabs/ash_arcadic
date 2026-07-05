defmodule AshArcadic.ManualRelationships.Traverse do
  @moduledoc """
  Bounded variable-length graph traversal as an Ash manual relationship.

      has_many :descendants, MyApp.Node do
        manual {AshArcadic.ManualRelationships.Traverse,
                edge_label: :PARENT_OF, direction: :outgoing, min_depth: 1, max_depth: 3,
                scope_edges: true}
      end

  `load/3` runs the Option-B two-phase read with **per-hop authorization**:

    * **Phase 1 (reachability).** One parameterized statement — `UNWIND $ids AS sid
      MATCH p=<pattern> WHERE <src-pk-match> [AND <tenant scope>] RETURN <src-pk cols>,
      b.<dest-pk> AS d, [n IN nodes(p) | n.<dest-pk>] AS path` — returns each matched path's
      **destination PK plus the PKs of EVERY node on that path**, not the vertices. For
      `:attribute`, the tenant scope binds the path and filters BOTH nodes and edges by the
      discriminator — `ALL(x IN nodes(p) WHERE x.<attr> = $tenant) AND ALL(r IN
      relationships(p) WHERE r.<attr> = $tenant)` — on by default; `scope_edges: false` opts
      out of the edge clause (probe E4).
    * **Phase 2 (authorized read).** A STANDARD authorized `Ash.read` over the union of EVERY
      path node's PK (destinations AND intermediates), narrowing `context.query` (which already
      carries the relationship/caller filter + sort + limit + domain + tenant). Row policy,
      field policy (redaction), and the `:attribute` tenant filter / `:context` tenant DB are
      all delegated to Ash — this module never decodes a vertex. NOTE: a caller/relationship
      `limit` applies over the UNION of all sources' reachable nodes, not per-source (a
      Slice-3+ lateral-join concern).
    * **Phase 3 (regroup).** Keeps a destination for a source only if it has a path whose EVERY
      node is authorized — so a destination reachable ONLY through a row-policy-denied
      intermediate is dropped (per-hop authorization), while a destination with any
      fully-authorized path survives. Emits records in authorized-read order (sort/limit
      survive), deduped per source and cardinality-aware.

  It returns a source-PK-keyed map of **authorized** destination records; authorization is
  enforced on EVERY node on the path, not only the returned destinations. This covers
  self-referential traversal (the shipped norm); a multi-resource path whose intermediates
  carry a different policy is a Slice-3 concern and fails closed here. A single-attribute
  destination primary key is required (composite → fail-closed value-free, mirroring the
  edge-write dest-PK rule). Values ride `params`; every interpolated identifier is
  `AshArcadic.Identifier.validate!`-checked. Tenancy is FAIL-CLOSED twice over: Phase 1
  scopes the path (or targets the per-tenant `:context` database), and Phase 2's authorized
  read re-applies the tenant filter / database.
  """

  @behaviour Ash.Resource.ManualRelationship

  alias Ash.Resource.ManualRelationship.Context
  alias AshArcadic.Cast
  alias AshArcadic.DataLayer
  alias AshArcadic.DataLayer.Info
  alias AshArcadic.Errors.QueryFailed
  alias AshArcadic.Identifier
  alias AshArcadic.Multitenancy
  alias AshArcadic.Telemetry
  alias AshArcadic.Transaction

  require Ash.Query

  @impl true
  def select(_opts), do: []

  @impl true
  def load([], _opts, _context), do: {:ok, %{}}

  def load(records, opts, %Context{} = context) do
    source = context.relationship.source
    dest = context.relationship.destination
    card = context.relationship.cardinality
    {_edge, direction, _min, max_depth, _scope_edges?} = opts_tuple = validate_opts!(opts)

    Telemetry.span(
      :traverse,
      %{
        resource: source,
        multitenancy: strategy(source),
        direction: direction,
        tenant?: not is_nil(context.tenant),
        in_transaction?: Transaction.in_transaction?()
      },
      fn ->
        {result, row_count} = do_load(records, context, source, dest, card, opts_tuple)
        {result, stop_meta(result, row_count, max_depth)}
      end
    )
  end

  @doc false
  # Validates the manual opts. Raises a value-free ArgumentError on any bad value
  # (config/programmer error). Returns {edge_label, direction, min_depth, max_depth,
  # scope_edges?} (scope_edges? default true — the `relationships(p)` opt-out is
  # `scope_edges: false`; used by build_traverse for :attribute paths only).
  def validate_opts!(opts) do
    edge_label =
      Keyword.get(opts, :edge_label) ||
        raise(ArgumentError, "traverse requires :edge_label")

    _ = Identifier.validate!(edge_label)
    direction = Keyword.get(opts, :direction, :outgoing)

    unless direction in [:outgoing, :incoming, :both] do
      raise ArgumentError, "traverse :direction must be :outgoing | :incoming | :both"
    end

    max_depth = Keyword.get(opts, :max_depth)
    min_depth = Keyword.get(opts, :min_depth, 1)

    unless is_integer(max_depth) and max_depth >= 1 do
      raise ArgumentError,
            "traverse :max_depth must be an integer >= 1 (unbounded `*` is forbidden)"
    end

    unless is_integer(min_depth) and min_depth >= 1 and min_depth <= max_depth do
      raise ArgumentError,
            "traverse :min_depth must be an integer with 1 <= min_depth <= max_depth"
    end

    scope_edges? = Keyword.get(opts, :scope_edges, true)

    unless is_boolean(scope_edges?) do
      raise ArgumentError, "traverse :scope_edges must be a boolean"
    end

    {edge_label, direction, min_depth, max_depth, scope_edges?}
  end

  @doc false
  # Pure per-node-scope decision from both endpoints' strategies/attrs:
  #   :none                      — no :attribute endpoint; no scoping.
  #   {:ok, attr}                — scope every path node by `attr` ($tenant).
  #   {:error, :mixed_attribute} — both endpoints :attribute with DIFFERENT attrs;
  #     one $tenant cannot honor two dimensions → fail closed (D21). Same-attr
  #     (the self-referential norm) scopes normally. Keying on BOTH endpoints (not
  #     dest alone) scopes a source-:attribute / dest-non-:attribute pair.
  def scope_decision(src_strategy, src_attr, dest_strategy, dest_attr) do
    cond do
      src_strategy == :attribute and dest_strategy == :attribute and src_attr != dest_attr ->
        {:error, :mixed_attribute}

      dest_strategy == :attribute ->
        {:ok, dest_attr}

      src_strategy == :attribute ->
        {:ok, src_attr}

      true ->
        :none
    end
  end

  @doc false
  # Pure Cypher builder. :attribute (per_hop_scope? true) emits a bound-path MATCH scoping
  # nodes AND edges by default: ALL(x IN nodes(p) WHERE x.<attr>=$tenant) AND
  # ALL(r IN relationships(p) WHERE r.<attr>=$tenant) (probe E4). scope_edges? false drops
  # the edge clause (node-only opt-out for out-of-band-edge graphs). :context/none: unscoped.
  # Every identifier validated; only $ids/$tenant carry values.
  def build_traverse(spec) do
    edge = Identifier.validate!(spec.edge_label)
    src = Identifier.validate!(spec.src_label)
    dst = Identifier.validate!(spec.dest_label)
    dest_pk = spec.dest_pk |> to_string() |> Identifier.validate!()
    src_match = src_match(spec.src_pkey)
    src_return = src_return(spec.src_pkey)
    pat = pattern(spec.direction, src, dst, edge, spec.min_depth, spec.max_depth)
    # Per-hop authorization (§7.2 amended): return each path's ordered node PKs so Phase 3 can
    # keep a destination only if it has a path whose EVERY node is authorized (probe: ArcadeDB
    # `[n IN nodes(p) | n.<pk>]`). The path binding `p=` is required in BOTH branches for nodes(p).
    ret = "RETURN #{src_return}, b.#{dest_pk} AS d, [n IN nodes(p) | n.#{dest_pk}] AS path"

    if spec.per_hop_scope? do
      attr = Identifier.validate!(spec.tenant_attr)
      node_scope = "ALL(x IN nodes(p) WHERE x.#{attr} = $tenant)"

      scope =
        if spec.scope_edges? do
          node_scope <> " AND ALL(r IN relationships(p) WHERE r.#{attr} = $tenant)"
        else
          node_scope
        end

      cypher =
        "UNWIND $ids AS sid MATCH p=#{pat} " <>
          "WHERE #{src_match} AND #{scope} " <>
          ret

      {cypher, %{"ids" => spec.ids, "tenant" => spec.tenant}}
    else
      cypher = "UNWIND $ids AS sid MATCH p=#{pat} WHERE #{src_match} " <> ret

      {cypher, %{"ids" => spec.ids}}
    end
  end

  defp pattern(:incoming, src, dst, edge, min, max),
    do: "(a:#{src})<-[:#{edge}*#{min}..#{max}]-(b:#{dst})"

  defp pattern(:both, src, dst, edge, min, max),
    do: "(a:#{src})-[:#{edge}*#{min}..#{max}]-(b:#{dst})"

  defp pattern(_outgoing, src, dst, edge, min, max),
    do: "(a:#{src})-[:#{edge}*#{min}..#{max}]->(b:#{dst})"

  defp src_match(src_pkey) do
    Enum.map_join(src_pkey, " AND ", fn f ->
      f = f |> to_string() |> Identifier.validate!()
      "a.#{f} = sid.#{f}"
    end)
  end

  defp src_return(src_pkey) do
    src_pkey
    |> Enum.with_index(1)
    |> Enum.map_join(", ", fn {f, i} ->
      f = f |> to_string() |> Identifier.validate!()
      "a.#{f} AS s#{i}"
    end)
  end

  @doc false
  # Phase-1 decode (Option B, §7.2 amended for per-hop authz). Reachability rows
  # (%{"s1" => .., ["s2" => .., ] "d" => .., "path" => [node PKs]}) → {reach_map, node_union}.
  # reach_map keys are the source-PK map (Cast.load_value-coerced so key === Map.take(record,
  # src_pkey) for Ash's normalize_manual_results); values are that source's PRE-DEDUP list of
  # path-entries %{dest: dest-PK, path: [every node PK on THAT path]} (genuine fan-out — one
  # entry per matched path — telemetry row_count). node_union is the de-duplicated UNION of
  # EVERY node PK on EVERY path (destinations AND intermediates) — the `pk in ^union` set the
  # authorized read must cover so Phase 3 can keep only destinations with a fully-authorized
  # path. NO vertex is decoded here (the authorized read materializes records). reach_spec =
  # %{src_pkey, src_types, dest_pk_type}; path nodes share the dest PK's runtime shape (self-
  # referential traversal — the shipped norm).
  def assemble_reachability(rows, %{
        src_pkey: src_pkey,
        src_types: src_types,
        dest_pk_type: dest_pk_type
      }) do
    indexed_pkey = Enum.with_index(src_pkey, 1)

    reach_map =
      rows
      |> Enum.reduce(%{}, fn row, acc ->
        src_key =
          Map.new(indexed_pkey, fn {atom, i} ->
            {atom, Cast.load_value(Map.get(row, "s#{i}"), Map.get(src_types, atom))}
          end)

        dval = Cast.load_value(Map.get(row, "d"), dest_pk_type)
        path = row |> path_pks() |> Enum.map(&Cast.load_value(&1, dest_pk_type))
        Map.update(acc, src_key, [%{dest: dval, path: path}], &[%{dest: dval, path: path} | &1])
      end)
      |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)

    node_union =
      rows
      |> Enum.flat_map(&path_pks/1)
      |> Enum.map(&Cast.load_value(&1, dest_pk_type))
      |> Enum.uniq()

    {reach_map, node_union}
  end

  # Raw (uncoerced) path node PKs for a reachability row; a row missing `path` contributes none.
  defp path_pks(row), do: Map.get(row, "path") || []

  defp cardinalize(records, :one), do: List.first(records)
  defp cardinalize(records, _many), do: records

  @doc false
  # Phase-3 regroup (Option B, §7.2 step 3, amended for per-hop authz). `authorized` is the
  # authorized-read record set over the FULL node union; a node is authorized iff its PK is in
  # that set. For each source, a destination SURVIVES iff it has ≥1 path-entry whose EVERY node
  # PK is authorized — a destination reachable ONLY through a row-policy-denied intermediate is
  # dropped, while a destination with any fully-authorized path is kept. Records are emitted by
  # iterating `authorized` in READ order (so sort/limit survive), unique by PK. Sources with no
  # surviving dest → cardinalize([], card). `dest_pk` is the destination's single PK atom.
  def regroup(reach_map, authorized, dest_pk, card) do
    authorized_set = MapSet.new(authorized, &Map.get(&1, dest_pk))

    Map.new(reach_map, fn {src_key, entries} ->
      surviving =
        for %{dest: dest, path: path} <- entries,
            Enum.all?(path, &MapSet.member?(authorized_set, &1)),
            into: MapSet.new(),
            do: dest

      recs = Enum.filter(authorized, fn r -> MapSet.member?(surviving, Map.get(r, dest_pk)) end)

      {src_key, cardinalize(recs, card)}
    end)
  end

  # Orchestration: resolve database + tenant scope + dest-PK + conn (all fail-closed), build
  # the Phase-1 reachability statement, run it, assemble reachability, then run the Phase-2
  # authorized read + Phase-3 regroup. Returns {result, pre_dedup_row_count} for telemetry.
  defp do_load(
         records,
         context,
         source,
         dest,
         card,
         {edge_label, direction, min_depth, max_depth, scope_edges?}
       ) do
    with {:ok, database} <- resolve_database(source, context.tenant),
         {:ok, tenant_attr, tenant} <- resolve_tenant(source, dest, context.tenant),
         {:ok, dest_pk} <- resolve_dest_pk(dest),
         {:ok, conn} <- resolve_conn(source, database),
         src_pkey = Ash.Resource.Info.primary_key(source),
         src_types = Info.attribute_types(source),
         ids = records |> Enum.map(&encode_id(&1, src_pkey, src_types)) |> Enum.uniq(),
         :ok <- check_ids_encodable(ids) do
      spec = %{
        direction: direction,
        edge_label: edge_label,
        min_depth: min_depth,
        max_depth: max_depth,
        src_label: Info.label(source),
        dest_label: Info.label(dest),
        src_pkey: src_pkey,
        dest_pk: dest_pk,
        tenant_attr: tenant_attr,
        tenant: tenant,
        per_hop_scope?: not is_nil(tenant_attr),
        scope_edges?: scope_edges?,
        ids: ids
      }

      {cypher, params} = build_traverse(spec)

      case Arcadic.query(conn, cypher, params) do
        {:ok, rows} ->
          reach_spec = %{
            src_pkey: src_pkey,
            src_types: src_types,
            dest_pk_type: Map.get(Info.attribute_types(dest), dest_pk)
          }

          {reach_map, node_union} = assemble_reachability(rows, reach_spec)
          {finish_load(reach_map, node_union, dest_pk, card, context), length(rows)}

        {:error, error} ->
          {{:error, wrap_traverse_error(error)}, 0}
      end
    else
      {:error, reason} -> {{:error, traverse_error(reason)}, 0}
    end
  end

  # Phase 2 (authorized read over EVERY path node) + Phase 3 (path-aware regroup). Empty
  # reachability → skip the read (no `IN []`); every source defaults empty via `regroup` over an
  # empty map.
  defp finish_load(_reach_map, [], _dest_pk, _card, _context), do: {:ok, %{}}

  defp finish_load(reach_map, node_union, dest_pk, card, context) do
    case authorized_read(context, dest_pk, node_union) do
      {:ok, authorized} -> {:ok, regroup(reach_map, authorized, dest_pk, card)}
      {:error, error} -> {:error, error}
    end
  end

  # The Option-B authorized read (§7.2 step 2, amended for per-hop authz). context.query already
  # carries the relationship/caller filter + sort + limit + domain + tenant (relationships.ex:
  # 600-611); we narrow it to the reachable node-PK union (destinations AND intermediates) and
  # run a STANDARD authorized Ash read. Routes through Ash's full read path → row policy (→
  # Cypher WHERE via filter/3) + field policy (redaction) + the :attribute tenant filter /
  # :context tenant DB. The returned set is EVERY authorized node on any path, so `regroup` can
  # keep only destinations reachable via a fully-authorized path. Records return already-
  # authorized, so Ash's PK-only post-load short-circuit (spec §2) cannot re-expose a denied
  # node. The read emits its own Slice-1 :read span beneath the :traverse span (§9).
  defp authorized_read(context, dest_pk, node_union) do
    context.query
    |> Ash.Query.filter(^Ash.Expr.ref(dest_pk) in ^node_union)
    |> Ash.read(
      actor: context.actor,
      authorize?: context.authorize?,
      tenant: context.tenant,
      domain: context.domain
    )
  end

  @doc false
  # The database to target. :context resolves the per-tenant DB (fail-closed on
  # blank); :attribute/none uses the resource's static `database` (may be nil → base
  # conn). Mirrors DataLayer.read_conn/2's database selection.
  def resolve_database(source, tenant) do
    if strategy(source) == :context do
      case blank_tenant(tenant) do
        :blank -> {:error, :tenant_required}
        :ok -> {:ok, Multitenancy.database_name(source, tenant)}
      end
    else
      {:ok, Info.database(source)}
    end
  end

  @doc false
  # The node-scope attribute + tenant, or a fail-closed error. :none → unscoped
  # (no :attribute endpoint). Mixed discriminators → fail closed BEFORE any query.
  # Blank tenant on a scoped traversal → fail closed.
  def resolve_tenant(source, dest, tenant) do
    case scope_decision(strategy(source), attr(source), strategy(dest), attr(dest)) do
      :none ->
        {:ok, nil, nil}

      {:error, :mixed_attribute} = err ->
        err

      {:ok, scope_attr} ->
        case blank_tenant(tenant) do
          :blank -> {:error, :tenant_required}
          :ok -> {:ok, scope_attr, tenant}
        end
    end
  end

  @doc false
  # Option B requires a single-attribute destination PK (the reachability RETURN is
  # `b.<pk> AS d`; the authorized read filters `pk in ^union`) — mirroring the edge-write
  # dest-PK rule (spec §6.3/S2-9, edge_cypher.ex:32-37). A composite dest PK fails CLOSED
  # value-free (never a MatchError, never the PK values). This drops NO shipped capability:
  # Slice-1 never wired a composite-dest traversal relationship (every traverse support
  # resource has a single-attribute PK; the only composite-dest reference was the pure
  # `assemble_rows/3` unit test, deleted this task) — it is a faithful §7.2 reading, not a
  # restriction-shaped narrowing (independent-review-confirmed 2026-07-05).
  def resolve_dest_pk(dest) do
    case Ash.Resource.Info.primary_key(dest) do
      [single] -> {:ok, single}
      _ -> {:error, :composite_destination_pk}
    end
  end

  # Route the database-targeted base conn through the transaction resolver: a plain
  # conn outside a tx; the session (read-own-writes) inside one. :read never errors on
  # the session guard, but the spec's error variants are handled by do_load's else.
  defp resolve_conn(source, database) do
    Transaction.resolve_conn(base_conn(source, database), :read)
  end

  defp base_conn(source, nil), do: Info.client(source).conn()

  defp base_conn(source, database),
    do: Arcadic.with_database(Info.client(source).conn(), database)

  # One $ids entry: source-PK fields stringified and serialized by attribute type so
  # the param matches the STORED form (binary→base64, date/decimal→string). Scalar PKs
  # are JSON-safe after this; a :map/:array PK nesting a raw binary, or a :string PK
  # holding invalid UTF-8, is NOT (serialize_value base64s only TOP-LEVEL binary-storage
  # values) — `check_ids_encodable/1` is the fail-closed backstop before the wire. The
  # RETURN side coerces back via Cast.load_value.
  defp encode_id(record, src_pkey, src_types) do
    Map.new(src_pkey, fn field ->
      {to_string(field), Cast.serialize_value(Map.get(record, field), Map.get(src_types, field))}
    end)
  end

  # Fail closed value-free if any serialized $ids value is not JSON-encodable — without
  # this, Req/Jason raises `Jason.EncodeError` with the offending bytes in its message at
  # the wire (AGENTS.md Rule 4) AND an uncaught crash crosses the callback boundary
  # instead of a redacted `{:error, _}`. Mirrors the write path's `encode_check`.
  defp check_ids_encodable(ids) do
    case first_unencodable_id_field(ids) do
      nil -> :ok
      field -> {:error, {:unencodable_id, field}}
    end
  end

  @doc false
  # First $ids PK-FIELD name whose serialized value is not JSON-encodable, or nil.
  # Returns the FIELD (a declared attribute name), never the value (Rule 4).
  def first_unencodable_id_field(ids) do
    ids
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.find_value(fn {field, value} ->
      case Jason.encode(value) do
        {:ok, _} -> nil
        {:error, _} -> field
      end
    end)
  end

  defp wrap_traverse_error(error),
    do:
      QueryFailed.exception(query: "ArcadeDB traversal", reason: DataLayer.redact_db_error(error))

  # Value-free error for a fail-closed resolve. The atom is the ONLY thing named —
  # never a tenant-derived database, attr, or Cypher (AGENTS.md Rule 4).
  defp traverse_error(:tenant_required),
    do: QueryFailed.exception(query: "ArcadeDB traversal", reason: "multitenancy tenant required")

  defp traverse_error(:mixed_attribute),
    do:
      QueryFailed.exception(
        query: "ArcadeDB traversal",
        reason: "traversal across resources with different multitenancy attributes is unsupported"
      )

  defp traverse_error({:unencodable_id, field}),
    do:
      QueryFailed.exception(
        query: "ArcadeDB traversal",
        reason: "primary-key field #{field} is not JSON-encodable"
      )

  defp traverse_error(:composite_destination_pk),
    do:
      QueryFailed.exception(
        query: "ArcadeDB traversal",
        reason: "traversal destination must have a single-attribute primary key"
      )

  # The next two clauses are DIALYZER-REQUIRED but RUNTIME-UNREACHABLE on this read path:
  # `Transaction.resolve_conn/2`'s @spec declares both atoms for BOTH modes, but in `:read`
  # mode it never emits them (a cross-DB read runs on its own conn; sessions open on writes).
  # They are kept to satisfy the typed union so `do_load`'s `else` is exhaustive (dialyzer
  # clean). NOTE the sibling `data_layer.ex` read path takes the opposite tack — it narrows
  # to `:tenant_required` and documents why the tx atoms can't occur (data_layer.ex:233-236);
  # both are correct, so do not "fix" one to match the other.
  defp traverse_error(:cross_database_transaction),
    do:
      QueryFailed.exception(
        query: "ArcadeDB traversal",
        reason: "transaction spans multiple databases (single-database sessions)"
      )

  defp traverse_error(:transaction_begin_failed),
    do:
      QueryFailed.exception(
        query: "ArcadeDB traversal",
        reason: "could not begin ArcadeDB transaction"
      )

  @doc false
  # Value-free telemetry stop metadata. row_count is the GENUINE pre-dedup reachability
  # fan-out (length of the raw Phase-1 rows) — NOT sourced from the regrouped map — so it
  # stays independent of the post-authorization destination_count (the invariant the
  # stop_meta/3 tripwire pins; spec §9).
  def stop_meta({:ok, map}, row_count, max_depth) do
    dests = map |> Map.values() |> Enum.map(&List.wrap/1) |> List.flatten()
    %{destination_count: length(dests), row_count: row_count, depth: max_depth, result: :ok}
  end

  def stop_meta({:error, _}, _row_count, max_depth),
    do: %{destination_count: 0, row_count: 0, depth: max_depth, result: :error}

  defp strategy(resource), do: Ash.Resource.Info.multitenancy_strategy(resource)

  defp attr(resource) do
    if strategy(resource) == :attribute do
      to_string(Ash.Resource.Info.multitenancy_attribute(resource))
    end
  end

  defp blank_tenant(t) when t in [nil, ""], do: :blank
  defp blank_tenant(_), do: :ok
end
