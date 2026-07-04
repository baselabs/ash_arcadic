defmodule AshArcadic.DataLayer.Verifiers.ValidateDatabaseTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  test "a static database name that is not a valid identifier fails compilation" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :database]} do
        defmodule Elixir.AshArcadic.Test.BadDb do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            database("bad name;")
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "database"
    refute err.message =~ "bad name;"
  end

  test "a valid static database compiles clean (positive control)" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.GoodDb do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer

        arcade do
          client(AshArcadic.Test.MockClient)
          database("my_db")
        end

        attributes do
          uuid_primary_key :id
        end
      end
    end
  end
end
