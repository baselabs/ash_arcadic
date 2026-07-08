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

    # Pins the `destination_attribute` slot of offending_join_attr/3 (previously exercised only for
    # `source_attribute`). A self-referential has_many makes destination_attribute LOCAL, so the
    # verifier can see its sensitivity — the case §6.5 names but the original suite left untested.
    test "a has_many whose destination_attribute is a local sensitive attr is rejected" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:relationships, :children]} do
          defmodule Elixir.AshArcadic.Test.BadDestAttrResource do
            use Ash.Resource,
              domain: AshArcadic.Test.Domain,
              validate_domain_inclusion?: false,
              data_layer: AshArcadic.DataLayer

            arcade do
              client(AshArcadic.Test.MockClient)
              label(:BadDestAttr)
              sensitive([:parent_key])
            end

            attributes do
              attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
              attribute :parent_key, :binary, public?: true
            end

            relationships do
              has_many :children, __MODULE__, destination_attribute: :parent_key
            end

            actions do
              defaults [:read]
            end
          end
        end

      assert err.message =~ "parent_key"
      assert err.message =~ "sensitive"
    end

    # Pins the many_to_many coverage MECHANISM: a join resource's join FK is caught via the join
    # resource's own `belongs_to` `source_attribute` (NOT via the `*_on_join_resource` slots, which
    # are dead for the declaring resource — closeout finding). Makes §6.5's "incl m2m" non-vacuous.
    test "a many_to_many join resource whose join FK (belongs_to source_attribute) is sensitive is rejected" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:relationships, :post]} do
          defmodule Elixir.AshArcadic.Test.BadJoinResource do
            use Ash.Resource,
              domain: AshArcadic.Test.Domain,
              validate_domain_inclusion?: false,
              data_layer: AshArcadic.DataLayer

            arcade do
              client(AshArcadic.Test.MockClient)
              label(:BadJoin)
              sensitive([:post_id])
            end

            attributes do
              attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
              attribute :post_id, :binary, public?: true
              attribute :tag_id, :string, public?: true
            end

            relationships do
              belongs_to :post, __MODULE__,
                source_attribute: :post_id,
                destination_attribute: :id,
                define_attribute?: false

              belongs_to :tag, __MODULE__,
                source_attribute: :tag_id,
                destination_attribute: :id,
                define_attribute?: false
            end

            actions do
              defaults [:read]
            end
          end
        end

      assert err.message =~ "post_id"
      assert err.message =~ "sensitive"
    end
  end
end
