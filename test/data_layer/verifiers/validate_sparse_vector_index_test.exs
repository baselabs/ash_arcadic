defmodule AshArcadic.DataLayer.Verifiers.ValidateSparseVectorIndexTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  # Spark emits verifier failures as diagnostics collected by Spark.Test (the ash_age port
  # convention, mirroring the ValidateVectorIndex test). A sparse index declares a
  # (tokens, weights) attribute PAIR; both must be stored, non-sensitive, array-typed.

  test "a valid sparse_vector_index over a (tokens, weights) pair compiles" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.SpVecOk do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer

        arcade do
          client(AshArcadic.Test.MockClient)
          sparse_vector_index(:sparse_embedding, tokens: :tokens, weights: :weights)
        end

        attributes do
          uuid_primary_key :id
          attribute :tokens, {:array, :integer}
          attribute :weights, {:array, :float}
        end
      end
    end
  end

  test "V1: a sparse_vector_index over an undeclared tokens attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sparse_vector_index]} do
        defmodule Elixir.AshArcadic.Test.SpVecV1 do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sparse_vector_index(:sparse_embedding, tokens: :ghost, weights: :weights)
          end

          attributes do
            uuid_primary_key :id
            attribute :weights, {:array, :float}
          end
        end
      end

    assert err.message =~ "not a declared attribute"
  end

  test "V1: a sparse_vector_index over a skipped weights attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sparse_vector_index]} do
        defmodule Elixir.AshArcadic.Test.SpVecSkip do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            skip([:weights])
            sparse_vector_index(:sparse_embedding, tokens: :tokens, weights: :weights)
          end

          attributes do
            uuid_primary_key :id
            attribute :tokens, {:array, :integer}
            attribute :weights, {:array, :float}
          end
        end
      end

    assert err.message =~ "skip"
  end

  test "V2: a sparse_vector_index over a sensitive weights attribute fails closed" do
    # `:binary` passes the sensitive verifier (binary-storage), isolating the V2 branch here.
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sparse_vector_index]} do
        defmodule Elixir.AshArcadic.Test.SpVecSensitive do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sensitive([:weights])
            sparse_vector_index(:sparse_embedding, tokens: :tokens, weights: :weights)
          end

          attributes do
            uuid_primary_key :id
            attribute :tokens, {:array, :integer}
            attribute :weights, :binary
          end
        end
      end

    assert err.message =~ "sensitive"
  end

  test "V3: a sparse_vector_index over a scalar (non-array) tokens attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sparse_vector_index]} do
        defmodule Elixir.AshArcadic.Test.SpVecScalar do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sparse_vector_index(:sparse_embedding, tokens: :tokens, weights: :weights)
          end

          attributes do
            uuid_primary_key :id
            attribute :tokens, :string
            attribute :weights, {:array, :float}
          end
        end
      end

    assert err.message =~ "array-typed"
  end

  test "the same attribute for both tokens and weights fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sparse_vector_index]} do
        defmodule Elixir.AshArcadic.Test.SpVecSame do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sparse_vector_index(:sparse_embedding, tokens: :tokens, weights: :tokens)
          end

          attributes do
            uuid_primary_key :id
            attribute :tokens, {:array, :integer}
          end
        end
      end

    assert err.message =~ "DISTINCT"
  end

  test "V4: a sparse name duplicating another sparse name fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sparse_vector_index]} do
        defmodule Elixir.AshArcadic.Test.SpVecDup do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sparse_vector_index(:sp, tokens: :t1, weights: :w1)
            sparse_vector_index(:sp, tokens: :t2, weights: :w2)
          end

          attributes do
            uuid_primary_key :id
            attribute :t1, {:array, :integer}
            attribute :w1, {:array, :float}
            attribute :t2, {:array, :integer}
            attribute :w2, {:array, :float}
          end
        end
      end

    assert err.message =~ "duplicate"
  end

  test "V4: a sparse name colliding with a dense vector_index name fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sparse_vector_index]} do
        defmodule Elixir.AshArcadic.Test.SpVecDenseCollide do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            vector_index(:embedding, dimensions: 8)
            sparse_vector_index(:embedding, tokens: :tokens, weights: :weights)
          end

          attributes do
            uuid_primary_key :id
            attribute :embedding, {:array, :float}
            attribute :tokens, {:array, :integer}
            attribute :weights, {:array, :float}
          end
        end
      end

    assert err.message =~ "collide" or err.message =~ "duplicate"
  end

  test "the failure message is value-free (attribute NAME only, no value)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sparse_vector_index]} do
        defmodule Elixir.AshArcadic.Test.SpVecValueFree do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sparse_vector_index(:sparse_embedding, tokens: :tokens, weights: :ghost)
          end

          attributes do
            uuid_primary_key :id
            attribute :tokens, {:array, :integer}
          end
        end
      end

    # The message names the attribute (developer config) but carries no ROW value.
    assert err.message =~ "ghost"
  end
end
