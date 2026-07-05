defmodule AshArcadic.ManualRelationships.TraverseTest do
  use ExUnit.Case, async: true

  alias AshArcadic.ManualRelationships.Traverse

  describe "validate_opts!/1" do
    test "defaults direction :outgoing, min_depth 1; returns {edge, dir, min, max}" do
      assert {:PARENT_OF, :outgoing, 1, 3} =
               Traverse.validate_opts!(edge_label: :PARENT_OF, max_depth: 3)
    end

    test "honors explicit direction + min_depth" do
      assert {:KNOWS, :incoming, 2, 4} =
               Traverse.validate_opts!(
                 edge_label: :KNOWS,
                 direction: :incoming,
                 min_depth: 2,
                 max_depth: 4
               )
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
          tenant_attr: nil,
          tenant: nil,
          per_hop_scope?: false,
          ids: [%{"id" => "p1"}]
        },
        Map.new(overrides)
      )
    end

    test ":context / no-scope — single MATCH, no path binding, ids-only params" do
      {cypher, params} = Traverse.build_traverse(base_spec(%{}))

      assert cypher ==
               "UNWIND $ids AS sid MATCH (a:Node)-[:PARENT_OF*1..3]->(b:Node) " <>
                 "WHERE a.id = sid.id RETURN a.id AS s1, b"

      assert params == %{"ids" => [%{"id" => "p1"}]}
    end

    test ":attribute — bound path p + native ALL(nodes(p)) predicate + $tenant param" do
      {cypher, params} =
        Traverse.build_traverse(
          base_spec(%{per_hop_scope?: true, tenant_attr: "org_id", tenant: "acme"})
        )

      assert cypher ==
               "UNWIND $ids AS sid MATCH p=(a:Node)-[:PARENT_OF*1..3]->(b:Node) " <>
                 "WHERE a.id = sid.id AND ALL(x IN nodes(p) WHERE x.org_id = $tenant) " <>
                 "RETURN a.id AS s1, b"

      assert params == %{"ids" => [%{"id" => "p1"}], "tenant" => "acme"}
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
      assert cypher =~ "RETURN a.org_id AS s1, a.node_id AS s2, b"
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

  describe "assemble_rows/3" do
    defmodule Dst do
      @moduledoc false
      defstruct [:id, :name]
    end

    defp assemble_spec do
      %{
        src_pkey: [:id],
        src_types: %{id: {Ash.Type.String, []}},
        dest_pkey: [:id],
        dest: Dst,
        dest_attr_map: %{id: "id", name: "name"},
        dest_attr_types: %{id: {Ash.Type.String, []}, name: {Ash.Type.String, []}}
      }
    end

    defp rows do
      # p1 reaches d1, d2, and d1 again (fan-out dup) ; p2 reaches d3. `b` carries
      # @-keys that must be ignored on decode.
      [
        %{"s1" => "p1", "b" => %{"@rid" => "#1:1", "@cat" => "v", "id" => "d1", "name" => "D1"}},
        %{"s1" => "p1", "b" => %{"@rid" => "#1:2", "@cat" => "v", "id" => "d2", "name" => "D2"}},
        %{"s1" => "p1", "b" => %{"@rid" => "#1:1", "@cat" => "v", "id" => "d1", "name" => "D1"}},
        %{"s1" => "p2", "b" => %{"@rid" => "#1:3", "@cat" => "v", "id" => "d3", "name" => "D3"}}
      ]
    end

    test ":many — source-PK-keyed map; dest deduped by PK; @-keys ignored" do
      result = Traverse.assemble_rows(rows(), assemble_spec(), :many)

      assert result[%{id: "p1"}] == [%Dst{id: "d1", name: "D1"}, %Dst{id: "d2", name: "D2"}]
      assert result[%{id: "p2"}] == [%Dst{id: "d3", name: "D3"}]

      # @rid/@cat never leak onto the decoded struct.
      refute Map.has_key?(hd(result[%{id: "p1"}]), :"@rid")
    end

    test "TRIPWIRE: row_count (pre-dedup) diverges from destination_count (post-dedup)" do
      result = Traverse.assemble_rows(rows(), assemble_spec(), :many)
      destinations = result |> Map.values() |> List.flatten()
      # 4 raw rows in; 3 unique destinations out (d1 deduped) — proves dedup ran.
      assert length(rows()) == 4
      assert length(destinations) == 3
    end

    test ":one cardinality returns the first destination, not a list" do
      result = Traverse.assemble_rows(rows(), assemble_spec(), :one)
      assert result[%{id: "p1"}] == %Dst{id: "d1", name: "D1"}
      assert result[%{id: "p2"}] == %Dst{id: "d3", name: "D3"}
    end

    test "empty rows → empty map" do
      assert Traverse.assemble_rows([], assemble_spec(), :many) == %{}
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
end
