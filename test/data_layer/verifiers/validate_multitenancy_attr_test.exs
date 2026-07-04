defmodule AshArcadic.DataLayer.Verifiers.ValidateMultitenancyAttrTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  test "an :attribute discriminator in `skip` is a fail-open hole => compile error" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :skip]} do
        defmodule Elixir.AshArcadic.Test.MtSkip do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            skip([:org_id])
          end

          attributes do
            uuid_primary_key :id
            attribute :org_id, :string
          end

          multitenancy do
            strategy :attribute
            attribute :org_id
          end
        end
      end

    # "fail-open" is unique to ValidateMultitenancyAttr's message; ValidateSkip also
    # emits at [:arcade, :skip] but says "perpetual StaleRecord" — so this pins the
    # attribution to THIS verifier rather than any error that happens to mention "skip".
    assert err.message =~ "fail-open"
  end

  test "a binary-storage discriminator scopes inconsistently => compile error" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:multitenancy, :attribute]} do
        defmodule Elixir.AshArcadic.Test.MtBinary do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
          end

          attributes do
            uuid_primary_key :id
            attribute :org_id, :binary
          end

          multitenancy do
            strategy :attribute
            attribute :org_id
          end
        end
      end

    assert err.message =~ "binary-storage"
  end

  test "a plaintext, non-skipped :attribute discriminator compiles clean" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.MtOk do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer

        arcade do
          client(AshArcadic.Test.MockClient)
        end

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end
      end
    end
  end
end
