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
end
