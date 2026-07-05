defmodule AshArcadic.Changes.CreateEdgeTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Changes.CreateEdge
  alias AshArcadic.Test.EdgeAttrPerson

  defp edge(overrides \\ []) do
    struct(
      %AshArcadic.Edge{
        name: :friends,
        label: :KNOWS,
        direction: :outgoing,
        destination: EdgeAttrPerson,
        properties: [:since]
      },
      overrides
    )
  end

  describe "build_create/6 — MERGE (multiple? false)" do
    test "scopes BOTH endpoints in the WHERE before the MERGE-rel, stamps + sets props" do
      {cypher, params} =
        CreateEdge.build_create(
          EdgeAttrPerson,
          edge(),
          %{"id" => "p1"},
          "p2",
          %{"since" => "2020"},
          {:tenant, :tenant, "org1"}
        )

      # WHERE scopes endpoints BEFORE MERGE (the locked isolation invariant)
      assert cypher =~ "MATCH (a:EAPerson), (b:EAPerson) WHERE a.id = $src_id AND b.id = $dst"
      assert cypher =~ "AND a.tenant = $tenant AND b.tenant = $tenant MERGE (a)-[e:KNOWS]->(b)"
      assert cypher =~ "ON CREATE SET e += $props, e.tenant = $tenant"
      assert cypher =~ "ON MATCH SET e += $props"
      assert cypher =~ "RETURN e"
      # never inline the identity into the MERGE node patterns
      refute cypher =~ "MERGE (a:EAPerson {"
      assert params["src_id"] == "p1"
      assert params["dst"] == "p2"
      assert params["tenant"] == "org1"
      assert params["props"] == %{"since" => "2020"}
    end

    test "incoming direction flips the arrow" do
      {cypher, _} =
        CreateEdge.build_create(
          EdgeAttrPerson,
          edge(direction: :incoming),
          %{"id" => "p1"},
          "p2",
          %{},
          nil
        )

      assert cypher =~ "MERGE (b)-[e:KNOWS]->(a)"
    end
  end

  describe "build_create/6 — CREATE (multiple? true)" do
    test "emits CREATE (parallel-edge capable), still endpoint+tenant scoped" do
      {cypher, _} =
        CreateEdge.build_create(
          EdgeAttrPerson,
          edge(multiple?: true),
          %{"id" => "p1"},
          "p2",
          %{"since" => "2020"},
          {:tenant, :tenant, "org1"}
        )

      assert cypher =~
               "WHERE a.id = $src_id AND b.id = $dst AND a.tenant = $tenant AND b.tenant = $tenant"

      assert cypher =~ "CREATE (a)-[e:KNOWS]->(b) SET e += $props, e.tenant = $tenant RETURN e"
      refute cypher =~ "MERGE"
    end
  end

  describe "edge_properties/2 (R4 runtime half + sparse + arg-type serialization)" do
    defp changeset(args, action_args) do
      %Ash.Changeset{
        resource: EdgeAttrPerson,
        arguments: args,
        action: %{arguments: action_args}
      }
    end

    test "collects declared props, rejects nil (sparse), serializes by arg type" do
      cs =
        changeset(%{since: "2020", weight: nil}, [
          %{name: :since, type: Ash.Type.String, constraints: []}
        ])

      assert {:ok, %{"since" => "2020"}} =
               CreateEdge.edge_properties(cs, %AshArcadic.Edge{properties: [:since, :weight]})
    end

    test "R4 runtime: a sensitive prop with a non-binary arg fails closed value-free (names key only)" do
      cs = %Ash.Changeset{
        resource: AshArcadic.Test.EdgeSensitivePerson,
        arguments: %{secret: "plaintext"},
        action: %{arguments: [%{name: :secret, type: Ash.Type.String, constraints: []}]}
      }

      assert {:error, :secret} =
               CreateEdge.edge_properties(cs, %AshArcadic.Edge{properties: [:secret]})
    end

    test "R4 runtime: a sensitive prop with an UNDECLARED arg fails closed value-free (no crash)" do
      # :secret is sensitive on EdgeSensitivePerson, value present, but the action
      # declares no `:secret` argument → type resolves nil. Must return {:error, :secret}
      # (the designed value-free path), NOT raise UndefinedFunctionError.
      cs = %Ash.Changeset{
        resource: AshArcadic.Test.EdgeSensitivePerson,
        arguments: %{secret: "plaintext"},
        action: %{arguments: []}
      }

      assert {:error, :secret} =
               CreateEdge.edge_properties(cs, %AshArcadic.Edge{properties: [:secret]})
    end

    test "a non-sensitive UNDECLARED string property serializes value-free (no crash on nil type)" do
      # :extra is a non-sensitive edge property with a string value but NO declared
      # action argument (only reachable via set_argument-injection) → type resolves
      # nil. Must serialize the raw scalar (untyped pass-through), NOT raise
      # (UndefinedFunctionError) nil.storage_type/1 from the unguarded else branch.
      cs = changeset(%{extra: "hello"}, [])

      assert {:ok, %{"extra" => "hello"}} =
               CreateEdge.edge_properties(cs, %AshArcadic.Edge{properties: [:extra]})
    end
  end
end
