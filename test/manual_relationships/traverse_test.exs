defmodule AshArcadic.ManualRelationships.TraverseTest do
  use ExUnit.Case, async: true

  alias AshArcadic.ManualRelationships.Traverse

  describe "validate_opts!/1" do
    test "defaults direction :outgoing, min_depth 1; returns {edge, dir, min, max, scope_edges?}" do
      assert {:PARENT_OF, :outgoing, 1, 3, true} =
               Traverse.validate_opts!(edge_label: :PARENT_OF, max_depth: 3)
    end

    test "honors explicit direction + min_depth" do
      assert {:KNOWS, :incoming, 2, 4, true} =
               Traverse.validate_opts!(
                 edge_label: :KNOWS,
                 direction: :incoming,
                 min_depth: 2,
                 max_depth: 4
               )
    end

    test "honors explicit scope_edges: false (the documented opt-out)" do
      assert {:KNOWS, :incoming, 2, 4, false} =
               Traverse.validate_opts!(
                 edge_label: :KNOWS,
                 direction: :incoming,
                 min_depth: 2,
                 max_depth: 4,
                 scope_edges: false
               )
    end

    test "raises value-free on a non-boolean scope_edges" do
      assert_raise ArgumentError, ~r/scope_edges must be a boolean/, fn ->
        Traverse.validate_opts!(edge_label: :E, max_depth: 2, scope_edges: :nope)
      end
    end

    test "raises value-free when :edge_label missing" do
      assert_raise ArgumentError, ~r/requires :edge_label/, fn ->
        Traverse.validate_opts!(max_depth: 2)
      end
    end

    test "raises on a bad direction" do
      assert_raise ArgumentError, ~r/:direction must be/, fn ->
        Traverse.validate_opts!(edge_label: :E, direction: :sideways, max_depth: 2)
      end
    end

    test "raises when :max_depth missing or < 1 (unbounded * forbidden)" do
      assert_raise ArgumentError, ~r/max_depth must be an integer >= 1/, fn ->
        Traverse.validate_opts!(edge_label: :E)
      end

      assert_raise ArgumentError, ~r/max_depth/, fn ->
        Traverse.validate_opts!(edge_label: :E, max_depth: 0)
      end
    end

    test "raises when min_depth < 1 or min_depth > max_depth" do
      assert_raise ArgumentError, ~r/min_depth/, fn ->
        Traverse.validate_opts!(edge_label: :E, min_depth: 0, max_depth: 2)
      end

      assert_raise ArgumentError, ~r/min_depth/, fn ->
        Traverse.validate_opts!(edge_label: :E, min_depth: 3, max_depth: 2)
      end
    end

    test "TRIPWIRE: raises value-free on a non-identifier edge_label (never echoes the value)" do
      err =
        assert_raise ArgumentError, fn ->
          Traverse.validate_opts!(edge_label: :"bad-label", max_depth: 2)
        end

      refute err.message =~ "bad-label"
    end
  end

  describe "scope_decision/4" do
    test ":none when neither endpoint is :attribute" do
      assert Traverse.scope_decision(:context, nil, :context, nil) == :none
      assert Traverse.scope_decision(nil, nil, nil, nil) == :none
    end

    test "scopes by dest attr when dest is :attribute" do
      assert Traverse.scope_decision(:context, nil, :attribute, "org_id") == {:ok, "org_id"}
    end

    test "scopes by source attr when only source is :attribute (closes the source-attr hole)" do
      assert Traverse.scope_decision(:attribute, "org_id", :context, nil) == {:ok, "org_id"}
    end

    test "same discriminator on both endpoints scopes normally (self-referential norm)" do
      assert Traverse.scope_decision(:attribute, "org_id", :attribute, "org_id") ==
               {:ok, "org_id"}
    end

    test "TRIPWIRE: both :attribute with DIFFERENT discriminators fails closed" do
      assert Traverse.scope_decision(:attribute, "org_id", :attribute, "team_id") ==
               {:error, :mixed_attribute}
    end
  end

  describe "build_traverse/1" do
    defp base_spec(overrides) do
      Map.merge(
        %{
          direction: :outgoing,
          edge_label: :PARENT_OF,
          min_depth: 1,
          max_depth: 3,
          src_label: :Node,
          dest_label: :Node,
          src_pkey: [:id],
          dest_pk: :id,
          tenant_attr: nil,
          tenant: nil,
          per_hop_scope?: false,
          scope_edges?: true,
          ids: [%{"id" => "p1"}]
        },
        Map.new(overrides)
      )
    end

    test ":none / no tenant scope — bound path p, ids-only params, path returned for per-hop authz" do
      {cypher, params} = Traverse.build_traverse(base_spec(%{}))

      assert cypher ==
               "UNWIND $ids AS sid MATCH p=(a:Node)-[:PARENT_OF*1..3]->(b:Node) " <>
                 "WHERE a.id = sid.id " <>
                 "RETURN a.id AS s1, b.id AS d, [n IN nodes(p) | n.id] AS path"

      assert params == %{"ids" => [%{"id" => "p1"}]}
    end

    test ":attribute default — bound path p + ALL(nodes(p)) AND ALL(relationships(p)) + $tenant" do
      {cypher, params} =
        Traverse.build_traverse(
          base_spec(%{per_hop_scope?: true, tenant_attr: "org_id", tenant: "acme"})
        )

      assert cypher ==
               "UNWIND $ids AS sid MATCH p=(a:Node)-[:PARENT_OF*1..3]->(b:Node) " <>
                 "WHERE a.id = sid.id AND ALL(x IN nodes(p) WHERE x.org_id = $tenant) " <>
                 "AND ALL(r IN relationships(p) WHERE r.org_id = $tenant) " <>
                 "RETURN a.id AS s1, b.id AS d, [n IN nodes(p) | n.id] AS path"

      assert params == %{"ids" => [%{"id" => "p1"}], "tenant" => "acme"}
    end

    test ":attribute scope_edges? false — node-only predicate (the documented opt-out)" do
      {cypher, _params} =
        Traverse.build_traverse(
          base_spec(%{
            per_hop_scope?: true,
            scope_edges?: false,
            tenant_attr: "org_id",
            tenant: "acme"
          })
        )

      assert cypher ==
               "UNWIND $ids AS sid MATCH p=(a:Node)-[:PARENT_OF*1..3]->(b:Node) " <>
                 "WHERE a.id = sid.id AND ALL(x IN nodes(p) WHERE x.org_id = $tenant) " <>
                 "RETURN a.id AS s1, b.id AS d, [n IN nodes(p) | n.id] AS path"

      refute cypher =~ "WHERE r.org_id"
    end

    test "direction :incoming / :both emit the correct edge arrows" do
      {inc, _} = Traverse.build_traverse(base_spec(%{direction: :incoming}))
      assert inc =~ "(a:Node)<-[:PARENT_OF*1..3]-(b:Node)"

      {both, _} = Traverse.build_traverse(base_spec(%{direction: :both}))
      assert both =~ "(a:Node)-[:PARENT_OF*1..3]-(b:Node)"
    end

    test "composite PK expands src-match (AND) and src-return (s1, s2)" do
      {cypher, _} = Traverse.build_traverse(base_spec(%{src_pkey: [:org_id, :node_id]}))
      assert cypher =~ "WHERE a.org_id = sid.org_id AND a.node_id = sid.node_id"

      assert cypher =~
               "RETURN a.org_id AS s1, a.node_id AS s2, b.id AS d, [n IN nodes(p) | n.id] AS path"
    end

    test "min_depth honored in the varlen bound" do
      {cypher, _} = Traverse.build_traverse(base_spec(%{min_depth: 2, max_depth: 4}))
      assert cypher =~ "*2..4"
    end

    test "TRIPWIRE: a non-identifier edge_label raises value-free (never interpolated)" do
      err =
        assert_raise ArgumentError, fn ->
          Traverse.build_traverse(base_spec(%{edge_label: :"e; DROP"}))
        end

      refute err.message =~ "DROP"
    end
  end

  describe "resolve_dest_pk/1 (Option B single-attribute dest-PK requirement)" do
    alias AshArcadic.Test.{TraverseAttrNode, UpsertComposite}

    test "single-attribute dest PK → {:ok, attr}" do
      assert Traverse.resolve_dest_pk(TraverseAttrNode) == {:ok, :id}
    end

    test "TRIPWIRE: composite dest PK fails closed value-free (never a MatchError, never PK values)" do
      assert Traverse.resolve_dest_pk(UpsertComposite) == {:error, :composite_destination_pk}
    end
  end

  describe "resolve_database/2 + resolve_tenant/3 (fail-closed seams, no server)" do
    alias AshArcadic.Test.{TraverseAttrNode, TraverseAttrTeam, TraverseContextNode}

    test "resolve_database :context blank tenant → :tenant_required" do
      assert Traverse.resolve_database(TraverseContextNode, "") == {:error, :tenant_required}
      assert Traverse.resolve_database(TraverseContextNode, nil) == {:error, :tenant_required}
    end

    test "resolve_database :context resolves the per-tenant database name" do
      assert Traverse.resolve_database(TraverseContextNode, "acme") == {:ok, "t_acme"}
    end

    test "resolve_database :attribute → static database (nil here, base conn)" do
      assert Traverse.resolve_database(TraverseAttrNode, "acme") == {:ok, nil}
    end

    test "resolve_tenant :none when neither endpoint is :attribute" do
      assert Traverse.resolve_tenant(TraverseContextNode, TraverseContextNode, "acme") ==
               {:ok, nil, nil}
    end

    test "resolve_tenant :attribute self-ref scopes by the discriminator" do
      assert Traverse.resolve_tenant(TraverseAttrNode, TraverseAttrNode, "acme") ==
               {:ok, "org_id", "acme"}
    end

    test "resolve_tenant :attribute blank tenant → :tenant_required" do
      assert Traverse.resolve_tenant(TraverseAttrNode, TraverseAttrNode, "") ==
               {:error, :tenant_required}
    end

    test "TRIPWIRE: resolve_tenant across DIFFERENT discriminators fails closed" do
      assert Traverse.resolve_tenant(TraverseAttrNode, TraverseAttrTeam, "acme") ==
               {:error, :mixed_attribute}
    end
  end

  describe "assemble_reachability/2" do
    defp reach_spec do
      %{
        src_pkey: [:id],
        src_types: %{id: {Ash.Type.String, []}},
        dest_pk_type: {Ash.Type.String, []}
      }
    end

    defp reach_rows do
      # p1: ->d1 direct ([p1,d1]); ->d2 through intermediate `m` ([p1,m,d2]); ->d1 again (dup).
      # p2: ->d3 ([p2,d3]); ->d1 ([p2,d1]).
      [
        %{"s1" => "p1", "d" => "d1", "path" => ["p1", "d1"]},
        %{"s1" => "p1", "d" => "d2", "path" => ["p1", "m", "d2"]},
        %{"s1" => "p1", "d" => "d1", "path" => ["p1", "d1"]},
        %{"s1" => "p2", "d" => "d3", "path" => ["p2", "d3"]},
        %{"s1" => "p2", "d" => "d1", "path" => ["p2", "d1"]}
      ]
    end

    test "source-PK-keyed reach map of path-entries (Ash Map.take shape), PRE-DEDUP fan-out" do
      {reach_map, _union} = Traverse.assemble_reachability(reach_rows(), reach_spec())

      assert reach_map[%{id: "p1"}] == [
               %{dest: "d1", path: ["p1", "d1"]},
               %{dest: "d2", path: ["p1", "m", "d2"]},
               %{dest: "d1", path: ["p1", "d1"]}
             ]

      assert reach_map[%{id: "p2"}] == [
               %{dest: "d3", path: ["p2", "d3"]},
               %{dest: "d1", path: ["p2", "d1"]}
             ]
    end

    test "node UNION is EVERY path node (destinations AND intermediates), de-duplicated" do
      {_reach_map, union} = Traverse.assemble_reachability(reach_rows(), reach_spec())

      # The intermediate `m` MUST be in the union so the authorized read covers it (per-hop authz);
      # a union of destinations only would let a denied intermediate go unauthorized.
      assert Enum.sort(union) == ["d1", "d2", "d3", "m", "p1", "p2"]
    end

    test "composite src PK builds a multi-field key from s1/s2" do
      spec = %{
        src_pkey: [:org_id, :node_id],
        src_types: %{org_id: {Ash.Type.String, []}, node_id: {Ash.Type.String, []}},
        dest_pk_type: {Ash.Type.String, []}
      }

      rows = [%{"s1" => "acme", "s2" => "n1", "d" => "d1", "path" => ["acme_n1", "d1"]}]
      {reach_map, union} = Traverse.assemble_reachability(rows, spec)

      assert reach_map[%{org_id: "acme", node_id: "n1"}] == [
               %{dest: "d1", path: ["acme_n1", "d1"]}
             ]

      assert Enum.sort(union) == ["acme_n1", "d1"]
    end

    test "empty rows → empty map + empty union" do
      assert Traverse.assemble_reachability([], reach_spec()) == {%{}, []}
    end
  end

  describe "surviving_dests/2 (per-hop authorization filter)" do
    # p1: d1 via [p1,d1] (authorized); d2 via [p1,mid,d2] crossing DENIED `mid`; d1 dup.
    # p3: d1 via BOTH [p3,mid,d1] (denied) AND [p3,d1] (clean) — the clean path must keep it.
    defp reach_map do
      %{
        %{id: "p1"} => [
          %{dest: "d1", path: ["p1", "d1"]},
          %{dest: "d2", path: ["p1", "mid", "d2"]},
          %{dest: "d1", path: ["p1", "d1"]}
        ],
        %{id: "p3"} => [
          %{dest: "d1", path: ["p3", "mid", "d1"]},
          %{dest: "d1", path: ["p3", "d1"]}
        ]
      }
    end

    # The ROW-POLICY-authorized node set (Read A). `mid` is DENIED (absent) — even though `d2`
    # (its downstream) IS authorized as a node.
    defp auth_set, do: MapSet.new(["p1", "p3", "d1", "d2", "d3"])

    test "TRIPWIRE: drops a dest whose ONLY path crosses a denied node — even when the dest itself is authorized" do
      surviving = Traverse.surviving_dests(reach_map(), auth_set())
      # d1 kept (path [p1,d1]); d2 dropped (only path crosses denied `mid`), though d2's PK is in
      # auth_set — this is per-hop (PATH) authz, which a destination-only check would miss.
      assert surviving[%{id: "p1"}] == MapSet.new(["d1"])
    end

    test "POSITIVE multi-path: a dest reachable via BOTH a denied AND a clean path is KEPT" do
      surviving = Traverse.surviving_dests(reach_map(), auth_set())

      # p3 reaches d1 via [p3,mid,d1] (denied) AND [p3,d1] (clean) → any fully-authorized path keeps it.
      assert surviving[%{id: "p3"}] == MapSet.new(["d1"])
    end

    test "a source whose every path is denied → empty set" do
      rmap = %{%{id: "p9"} => [%{dest: "d9", path: ["p9", "mid", "d9"]}]}
      assert Traverse.surviving_dests(rmap, auth_set()) == %{%{id: "p9"} => MapSet.new()}
    end
  end

  describe "regroup/4 (final assembly, read-order-preserving)" do
    defmodule RDst do
      @moduledoc false
      defstruct [:id, :name]
    end

    # Per-source surviving dest-PK sets (output of surviving_dests).
    defp surviving do
      %{%{id: "p1"} => MapSet.new(["d1"]), %{id: "p2"} => MapSet.new(["d1", "d3"])}
    end

    # The authorized DESTINATION read (Read B), IN READ ORDER (e.g. caller sort by name).
    defp records, do: [%RDst{id: "d1", name: "A"}, %RDst{id: "d3", name: "C"}]

    test ":many — per-source records = surviving ∩ records, in READ order" do
      result = Traverse.regroup(surviving(), records(), :id, :many)
      assert result[%{id: "p1"}] == [%RDst{id: "d1", name: "A"}]
      assert result[%{id: "p2"}] == [%RDst{id: "d1", name: "A"}, %RDst{id: "d3", name: "C"}]
    end

    test "read-order is preserved (caller sort survives)" do
      # p2 surviving {d1,d3}; records order is [d1(A), d3(C)] → regroup follows READ order.
      result = Traverse.regroup(surviving(), records(), :id, :many)
      assert Enum.map(result[%{id: "p2"}], & &1.id) == ["d1", "d3"]
    end

    test ":one — first surviving record in read order, or nil" do
      result = Traverse.regroup(surviving(), records(), :id, :one)
      assert result[%{id: "p1"}] == %RDst{id: "d1", name: "A"}
      assert result[%{id: "p2"}] == %RDst{id: "d1", name: "A"}
    end

    test "a dest that survived per-hop but is absent from Read B (caller filter dropped it) → [] / nil" do
      # p1 surviving {d1}, but Read B returned no matching record (e.g. caller filter excluded d1).
      assert Traverse.regroup(%{%{id: "p1"} => MapSet.new(["d1"])}, [], :id, :many) ==
               %{%{id: "p1"} => []}

      assert Traverse.regroup(%{%{id: "p1"} => MapSet.new(["d1"])}, [], :id, :one) ==
               %{%{id: "p1"} => nil}
    end
  end

  describe "first_unencodable_id_field/1 ($ids encode-gate, Rule 4)" do
    test "nil when all id values are JSON-encodable scalars" do
      assert Traverse.first_unencodable_id_field([%{"id" => "p1"}]) == nil
      assert Traverse.first_unencodable_id_field([%{"a" => "x", "b" => 42}]) == nil
    end

    test "TRIPWIRE: flags a NESTED non-UTF8 binary (map PK) by FIELD name, never the value" do
      poison = [%{"id" => %{"k" => <<0xFF, 0x00, 0x42>>}}]
      assert Traverse.first_unencodable_id_field(poison) == "id"
    end

    test "flags a raw non-UTF8 binary id value (a :string PK holding invalid UTF-8)" do
      assert Traverse.first_unencodable_id_field([%{"id" => <<0xFF>>}]) == "id"
    end
  end

  # Restores the tripwire deleted with assemble_rows/3 (Task 6): telemetry row_count is the
  # GENUINE pre-dedup reachability fan-out (length of the raw Phase-1 rows), independent of the
  # post-authorization destination_count. A stop_meta that sourced row_count from the regrouped
  # map (post-dedup / post-policy-drop) would collapse the two — this pins that they diverge.
  describe "stop_meta/3 (telemetry pre-dedup fan-out invariant)" do
    defmodule SMDst do
      @moduledoc false
      defstruct [:id]
    end

    test "TRIPWIRE: row_count (pre-dedup fan-out) diverges from destination_count (post-regroup)" do
      d1 = %SMDst{id: "d1"}
      d2 = %SMDst{id: "d2"}
      d3 = %SMDst{id: "d3"}
      # 5 raw reachability rows fanned in (row_count); after the authorized read + regroup only
      # 4 delivered records remain (one reachable dest was policy-denied / filtered out).
      regrouped = %{%{id: "p1"} => [d1, d2], %{id: "p2"} => [d1, d3]}

      meta = Traverse.stop_meta({:ok, regrouped}, 5, 3)

      assert meta.row_count == 5
      assert meta.destination_count == 4
      refute meta.row_count == meta.destination_count
      assert meta.depth == 3
      assert meta.result == :ok
    end

    test ":one cardinality (single-record values) counts each delivered destination once" do
      meta =
        Traverse.stop_meta({:ok, %{%{id: "p1"} => %SMDst{id: "d1"}, %{id: "p2"} => nil}}, 2, 3)

      # List.wrap(nil) => [] (a source with no surviving dest contributes 0).
      assert meta.destination_count == 1
      assert meta.row_count == 2
    end

    test ":error result zeroes both counts value-free" do
      assert Traverse.stop_meta({:error, :boom}, 5, 3) ==
               %{destination_count: 0, row_count: 0, depth: 3, result: :error}
    end
  end
end
