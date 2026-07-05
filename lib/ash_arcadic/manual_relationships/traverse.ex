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

  alias AshArcadic.Cast
  alias AshArcadic.Identifier

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
end
