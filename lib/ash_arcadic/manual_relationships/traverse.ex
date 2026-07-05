defmodule AshArcadic.ManualRelationships.Traverse do
  @moduledoc """
  Bounded variable-length graph traversal as an Ash manual relationship.

      has_many :descendants, MyApp.Node do
        manual {AshArcadic.ManualRelationships.Traverse,
                edge_label: :PARENT_OF, direction: :outgoing, min_depth: 1, max_depth: 3}
      end

  `load/3` emits one parameterized statement — `UNWIND $ids AS sid MATCH <pattern>
  WHERE <src-pk-match> [AND ALL(x IN nodes(p) WHERE x.<attr> = $tenant)] RETURN
  <src-pk cols>, b` — and returns a source-PK-keyed map of decoded destination
  records (deduped per source, cardinality-aware). Values ride `params`; every
  interpolated identifier is `AshArcadic.Identifier.validate!`-checked. Tenancy is
  FAIL-CLOSED: `:context` resolves a per-tenant database; `:attribute` scopes every
  node on the bound path via the native predicate (probe P7 — NOT ash_age's
  UNION-ALL expansion, which Apache AGE forced). Rows are decoded from the
  `Arcadic.query` map shape (`%{"s1" => .., "b" => %{..vertex..}}`), not agtype.
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

  @impl true
  def select(_opts), do: []

  @impl true
  def load([], _opts, _context), do: {:ok, %{}}

  def load(records, opts, %Context{} = context) do
    source = context.relationship.source
    dest = context.relationship.destination
    card = context.relationship.cardinality
    {_edge, direction, _min, max_depth} = opts_tuple = validate_opts!(opts)

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
  # (config/programmer error). Returns {edge_label_atom, direction, min_depth, max_depth}.
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

    {edge_label, direction, min_depth, max_depth}
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
  # Pure Cypher builder. `:attribute` (per_hop_scope? true) emits ONE bound-path
  # MATCH with the native predicate ALL(x IN nodes(p) WHERE x.<attr> = $tenant)
  # (probe P7 — replaces ash_age's UNION-ALL, which AGE forced). No SQL DISTINCT:
  # per-path rows are raw so row_count is the genuine pre-dedup fan-out; Elixir
  # dedup (Task 4) yields destination_count. Every identifier is validated; only
  # $ids/$tenant carry values.
  def build_traverse(spec) do
    edge = Identifier.validate!(spec.edge_label)
    src = Identifier.validate!(spec.src_label)
    dst = Identifier.validate!(spec.dest_label)
    src_match = src_match(spec.src_pkey)
    src_return = src_return(spec.src_pkey)
    pat = pattern(spec.direction, src, dst, edge, spec.min_depth, spec.max_depth)

    if spec.per_hop_scope? do
      attr = Identifier.validate!(spec.tenant_attr)

      cypher =
        "UNWIND $ids AS sid MATCH p=#{pat} " <>
          "WHERE #{src_match} AND ALL(x IN nodes(p) WHERE x.#{attr} = $tenant) " <>
          "RETURN #{src_return}, b"

      {cypher, %{"ids" => spec.ids, "tenant" => spec.tenant}}
    else
      cypher =
        "UNWIND $ids AS sid MATCH #{pat} WHERE #{src_match} RETURN #{src_return}, b"

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
  # Assembles the F3 source-PK-keyed map from the flat map-rows Arcadic.query
  # returns (`%{"s1" => .., "b" => %{..vertex..}}`). Source-PK scalars coerce back
  # to runtime shape via Cast.load_value (so the key === Map.take(record, src_pkey)
  # Ash matches). Dest vertices decode via Cast.row_to_attrs (ignores @-keys), then
  # dedup by dest PK and cardinalize. `spec` = %{src_pkey, src_types, dest_pkey,
  # dest, dest_attr_map, dest_attr_types}.
  def assemble_rows(rows, spec, card) do
    %{src_pkey: src_pkey, src_types: src_types, dest_pkey: dest_pkey} = spec
    indexed_pkey = Enum.with_index(src_pkey, 1)

    rows
    |> Enum.reduce(%{}, fn row, acc ->
      src_key =
        Map.new(indexed_pkey, fn {atom, i} ->
          {atom, Cast.load_value(Map.get(row, "s#{i}"), Map.get(src_types, atom))}
        end)

      b_record = decode_record(Map.get(row, "b"), spec)
      Map.update(acc, src_key, [b_record], &[b_record | &1])
    end)
    |> Map.new(fn {k, recs} -> {k, cardinalize(dedup(Enum.reverse(recs), dest_pkey), card)} end)
  end

  defp decode_record(vertex, %{dest: dest, dest_attr_map: attr_map, dest_attr_types: attr_types}) do
    struct(dest, Cast.row_to_attrs(vertex, attr_map, attr_types))
  end

  defp dedup(records, dest_pkey) do
    {out, _seen} =
      Enum.reduce(records, {[], MapSet.new()}, fn r, {out, seen} ->
        key = Map.take(r, dest_pkey)
        if MapSet.member?(seen, key), do: {out, seen}, else: {[r | out], MapSet.put(seen, key)}
      end)

    Enum.reverse(out)
  end

  defp cardinalize(records, :one), do: List.first(records)
  defp cardinalize(records, _many), do: records

  # Orchestration: resolve database + tenant scope + conn (all fail-closed), build the
  # one statement, run it, assemble. Returns {result, pre_dedup_row_count} for telemetry.
  defp do_load(
         records,
         context,
         source,
         dest,
         card,
         {edge_label, direction, min_depth, max_depth}
       ) do
    with {:ok, database} <- resolve_database(source, context.tenant),
         {:ok, tenant_attr, tenant} <- resolve_tenant(source, dest, context.tenant),
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
        tenant_attr: tenant_attr,
        tenant: tenant,
        per_hop_scope?: not is_nil(tenant_attr),
        ids: ids
      }

      {cypher, params} = build_traverse(spec)

      case Arcadic.query(conn, cypher, params) do
        {:ok, rows} ->
          {{:ok, assemble_rows(rows, assemble_spec(dest, src_pkey, src_types), card)},
           length(rows)}

        {:error, error} ->
          {{:error, wrap_traverse_error(error)}, 0}
      end
    else
      {:error, reason} -> {{:error, traverse_error(reason)}, 0}
    end
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

  # Route the database-targeted base conn through the transaction resolver: a plain
  # conn outside a tx; the session (read-own-writes) inside one. :read never errors on
  # the session guard, but the spec's error variants are handled by do_load's else.
  defp resolve_conn(source, database) do
    Transaction.resolve_conn(base_conn(source, database), :read)
  end

  defp base_conn(source, nil), do: Info.client(source).conn()

  defp base_conn(source, database),
    do: Arcadic.with_database(Info.client(source).conn(), database)

  defp assemble_spec(dest, src_pkey, src_types) do
    %{
      src_pkey: src_pkey,
      src_types: src_types,
      dest_pkey: Ash.Resource.Info.primary_key(dest),
      dest: dest,
      dest_attr_map: Info.attribute_map(dest),
      dest_attr_types: Info.attribute_types(dest)
    }
  end

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

  defp stop_meta({:ok, map}, row_count, max_depth) do
    dests = map |> Map.values() |> Enum.map(&List.wrap/1) |> List.flatten()
    %{destination_count: length(dests), row_count: row_count, depth: max_depth, result: :ok}
  end

  defp stop_meta({:error, _}, _row_count, max_depth),
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
