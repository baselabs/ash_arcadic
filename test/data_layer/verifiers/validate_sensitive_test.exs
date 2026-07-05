defmodule AshArcadic.DataLayer.Verifiers.ValidateSensitiveTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  # Spark emits verifier failures as diagnostics; use Spark.Test to collect them
  # from modules defined in the do-block (per the ash_age port convention).

  test "R1: a sensitive attr that is not a declared attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sensitive]} do
        defmodule Elixir.AshArcadic.Test.SensR1 do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sensitive([:ghost])
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "not a declared attribute"
  end

  test "R2: a plaintext (String) sensitive attr, not skipped, fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sensitive]} do
        defmodule Elixir.AshArcadic.Test.SensR2 do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sensitive([:ssn])
          end

          attributes do
            uuid_primary_key :id
            attribute :ssn, :string
          end
        end
      end

    assert err.message =~ "binary-storage-typed or listed"
  end

  test "R2: a sensitive {:array, :binary} attr is NOT binary-storage and fails closed" do
    # An array stores as a JSON array of base64 strings, not a single encrypted
    # binary, so `Cast.binary_storage?/2` reports false for `{:array, Ash.Type.Binary}`
    # (the normalized form Ash gives the attribute). Classifying it `sensitive`
    # without `skip` must fail closed — this locks that (ash_age ValidateSensitive
    # pins the same case).
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sensitive]} do
        defmodule Elixir.AshArcadic.Test.SensArray do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sensitive([:tags])
          end

          attributes do
            uuid_primary_key :id
            attribute :tags, {:array, :binary}
          end
        end
      end

    assert err.message =~ "binary-storage-typed or listed"
  end

  test "R2 passes: a :binary sensitive attr compiles clean" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.SensBin do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer

        arcade do
          client(AshArcadic.Test.MockClient)
          sensitive([:ssn])
        end

        attributes do
          uuid_primary_key :id
          attribute :ssn, :binary
        end
      end
    end
  end

  test "R2 passes: a SKIPPED sensitive attr compiles clean even if plaintext" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.SensSkip do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer

        arcade do
          client(AshArcadic.Test.MockClient)
          sensitive([:ssn])
          skip([:ssn])
        end

        attributes do
          uuid_primary_key :id
          attribute :ssn, :string
        end
      end
    end
  end

  test "R3: the multitenancy discriminator cannot be sensitive" do
    # org_id is :string (not :binary) so R3 (not_discriminator, checked before R2 in
    # the with-chain) is the sole trigger here. Task 13 adds a multitenancy-attr
    # binary check; because org_id is :string it will stay silent on this fixture
    # too, so R3 remains the only firing rule after that lands.
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sensitive]} do
        defmodule Elixir.AshArcadic.Test.SensR3 do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sensitive([:org_id])
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

    assert err.message =~ "plaintext selector"
  end

  describe "R4 — sensitive edge properties" do
    test "rejects a sensitive edge-property key whose same-named action arg is not binary-storage" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sensitive]} do
          defmodule Elixir.AshArcadic.Test.R4Plaintext do
            use Ash.Resource,
              domain: AshArcadic.Test.Domain,
              validate_domain_inclusion?: false,
              data_layer: AshArcadic.DataLayer

            arcade do
              client(AshArcadic.Test.MockClient)
              sensitive([:secret])

              edge :links do
                label(:LINKS)
                destination(__MODULE__)
                properties([:secret])
              end
            end

            attributes do
              uuid_primary_key :id
              attribute :secret, :binary
            end

            actions do
              defaults [:read]

              create :link do
                argument :secret, :string
                argument :to, :uuid
              end
            end
          end
        end

      assert err.message =~ "names a sensitive attribute"
    end

    test "accepts when the same-named arg is binary-storage-typed (positive control)" do
      refute_dsl_errors do
        defmodule Elixir.AshArcadic.Test.R4Binary do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            sensitive([:secret])

            edge :links do
              label(:LINKS)
              destination(__MODULE__)
              properties([:secret])
            end
          end

          attributes do
            uuid_primary_key :id
            attribute :secret, :binary
          end

          actions do
            defaults [:read]

            create :link do
              argument :secret, :binary
              argument :to, :uuid
            end
          end
        end
      end
    end
  end
end
