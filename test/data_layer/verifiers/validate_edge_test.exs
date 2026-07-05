defmodule AshArcadic.DataLayer.Verifiers.ValidateEdgeTest do
  use ExUnit.Case, async: true
  # Spark emits verifier failures as diagnostics; Spark.Test collects them from
  # modules defined in the do-block. `assert_dsl_error` MATCH-checks a
  # %Spark.Error.DslError{} struct (NOT a regex) and returns it for message asserts.
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  test "rejects an edge whose label is not a valid identifier" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :edge, :friends]} do
        defmodule Elixir.AshArcadic.Test.BadEdgeLabel do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)

            edge :friends do
              label(:"has space")
              destination(__MODULE__)
            end
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "invalid ArcadeDB identifier"
  end

  test "rejects an edge whose label leads with an underscore (Arcadic leading-letter rule)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :edge, :friends]} do
        defmodule Elixir.AshArcadic.Test.BadEdgeLeadingUnderscore do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)

            edge :friends do
              label(:_leading)
              destination(__MODULE__)
            end
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "invalid ArcadeDB identifier"
  end

  test "rejects an edge whose property key is not a valid identifier" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :edge, :friends]} do
        defmodule Elixir.AshArcadic.Test.BadEdgeProp do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)

            edge :friends do
              label(:KNOWS)
              destination(__MODULE__)
              properties([:"bad-prop"])
            end
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "invalid ArcadeDB identifier"
  end

  test "accepts a valid edge (positive control)" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.GoodEdge do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer

        arcade do
          client(AshArcadic.Test.MockClient)

          edge :friends do
            label(:KNOWS)
            destination(__MODULE__)
            properties([:since])
          end
        end

        attributes do
          uuid_primary_key :id
        end
      end
    end
  end
end
