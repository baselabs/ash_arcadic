defmodule AshArcadic.DataLayer.Verifiers.ValidateVectorIndexTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  # Spark emits verifier failures as diagnostics; Spark.Test collects them from the
  # module defined in the do-block (the ash_age port convention, per the sibling
  # ValidateSensitive test).

  test "a valid array-typed, non-sensitive, stored vector_index compiles" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.VecOk do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer

        arcade do
          client(AshArcadic.Test.MockClient)
          vector_index(:embedding, dimensions: 8, similarity: :cosine)
        end

        attributes do
          uuid_primary_key :id
          attribute :embedding, {:array, :float}
        end
      end
    end
  end

  test "V1: a vector_index over an undeclared attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :vector_index]} do
        defmodule Elixir.AshArcadic.Test.VecV1 do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            vector_index(:ghost, dimensions: 8)
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "not a declared attribute"
  end

  test "V1: a vector_index over a skipped attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :vector_index]} do
        defmodule Elixir.AshArcadic.Test.VecSkip do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            skip([:embedding])
            vector_index(:embedding, dimensions: 8)
          end

          attributes do
            uuid_primary_key :id
            attribute :embedding, {:array, :float}
          end
        end
      end

    assert err.message =~ "skip"
  end

  test "V2: a vector_index over a sensitive attribute fails closed" do
    # `:binary` passes the sensitive verifier (binary-storage), so only THIS verifier
    # errors — isolating the V2 (sensitive) branch on path [:arcade, :vector_index].
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :vector_index]} do
        defmodule Elixir.AshArcadic.Test.VecSensitive do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sensitive([:embedding])
            vector_index(:embedding, dimensions: 8)
          end

          attributes do
            uuid_primary_key :id
            attribute :embedding, :binary
          end
        end
      end

    assert err.message =~ "sensitive"
  end

  test "V3: a vector_index over a scalar (non-array) attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :vector_index]} do
        defmodule Elixir.AshArcadic.Test.VecScalar do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            vector_index(:embedding, dimensions: 8)
          end

          attributes do
            uuid_primary_key :id
            attribute :embedding, :string
          end
        end
      end

    assert err.message =~ "array-typed"
  end

  test "V4: duplicate vector_index names fail closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :vector_index]} do
        defmodule Elixir.AshArcadic.Test.VecDup do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            vector_index(:embedding, dimensions: 8)
            vector_index(:embedding, dimensions: 16)
          end

          attributes do
            uuid_primary_key :id
            attribute :embedding, {:array, :float}
          end
        end
      end

    assert err.message =~ "duplicate"
  end
end
