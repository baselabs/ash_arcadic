defmodule AshArcadic.DataLayer.Verifiers.ValidateSkipTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  test "a primary-key attribute in `skip` fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :skip]} do
        defmodule Elixir.AshArcadic.Test.SkipPk do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            skip([:id])
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "primary key"
  end

  test "a non-primary-key attribute in `skip` compiles clean (positive control)" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.SkipNonPk do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer

        arcade do
          client(AshArcadic.Test.MockClient)
          skip([:name])
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end
      end
    end
  end
end
