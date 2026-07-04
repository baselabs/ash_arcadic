defmodule AshArcadic.DataLayer.Verifiers.ValidateLabelFormatTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  test "a label that is not a valid identifier fails compilation with a DslError" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :label]} do
        defmodule Elixir.AshArcadic.Test.BadLabel do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            label(:"1bad")
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "label"
  end

  test "a valid explicit label compiles clean (positive control)" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.GoodLabel do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer

        arcade do
          client(AshArcadic.Test.MockClient)
          label(:Person)
        end

        attributes do
          uuid_primary_key :id
        end
      end
    end
  end
end
