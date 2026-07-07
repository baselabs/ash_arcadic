defmodule AshArcadic.RelationshipTest do
  use ExUnit.Case, async: true
  # Spark emits verifier failures as diagnostics (NOT a raised exception the caller
  # can `assert_raise` on); use Spark.Test to collect them from modules defined in the
  # do-block — the same convention every other verifier test in this repo follows.
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  describe "ValidateRelationshipFk — a sensitive join attribute fails closed at compile" do
    test "a belongs_to whose FK (source_attribute) is sensitive is rejected" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:relationships, :owner]} do
          defmodule Elixir.AshArcadic.Test.BadFkResource do
            use Ash.Resource,
              domain: AshArcadic.Test.Domain,
              validate_domain_inclusion?: false,
              data_layer: AshArcadic.DataLayer

            arcade do
              client(AshArcadic.Test.MockClient)
              label(:BadFk)
              sensitive([:owner_id])
            end

            attributes do
              attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
              attribute :owner_id, :binary, public?: true
            end

            relationships do
              belongs_to :owner, __MODULE__,
                source_attribute: :owner_id,
                destination_attribute: :id,
                define_attribute?: false
            end

            actions do
              defaults [:read]
            end
          end
        end

      assert err.message =~ "owner_id"
      assert err.message =~ "sensitive"
      # value-free: names the attribute atom + reason, never a value
      refute err.message =~ "cipher"
    end

    test "a non-sensitive FK compiles clean (positive control)" do
      refute_dsl_errors do
        defmodule Elixir.AshArcadic.Test.GoodFkResource do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer

          arcade do
            client(AshArcadic.Test.MockClient)
            label(:GoodFk)
          end

          attributes do
            attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
            attribute :owner_id, :string, public?: true
          end

          relationships do
            belongs_to :owner, __MODULE__,
              source_attribute: :owner_id,
              destination_attribute: :id,
              define_attribute?: false
          end

          actions do
            defaults [:read]
          end
        end
      end
    end
  end
end
