defmodule AshArcadic.Replicant.VerifierTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  # Check 1 — a `:context` multitenancy strategy on a replicant resource maps tenants
  # to different ArcadeDB databases, so a tenant-blind Postgres txn's cross-tenant
  # writes fail `:cross_database_transaction`, shattering effect-once. Only `:attribute`
  # or absent tenancy is allowed; `:context` => compile error.
  test "a :context multitenancy replicant resource is an effect-once violation => compile error" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:multitenancy, :strategy]} do
        defmodule Elixir.AshArcadic.Test.ReplicantContextMirror do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer,
            extensions: [AshArcadic.Replicant]

          arcade do
            client(AshArcadic.Test.MockClient)
          end

          replicant do
            source_table("orders")
          end

          attributes do
            uuid_primary_key :id
          end

          multitenancy do
            strategy :context
          end

          actions do
            defaults [:read]
          end
        end
      end

    # "effect-once" is unique to the replicant single-DB-tenancy verifier's message.
    assert err.message =~ "effect-once"
  end

  # Check 2 (F4) — the "a `sensitive` attribute must be encrypted-binary or `skip`ped"
  # compile invariant is ALREADY enforced by the landed
  # `AshArcadic.DataLayer.Verifiers.ValidateSensitive` (R2), which runs on every
  # `AshArcadic.DataLayer` resource — and a replicant resource IS one.
  # `AshArcadic.Replicant` exposes NO per-column mapping DSL (only source_schema/
  # source_table/tenant_attribute/skip/on_truncate), and the graph resource's dsl_state
  # never carries the Postgres source's column classification — so there is no
  # additional, non-duplicative compile invariant for the replicant *mapping* to enforce
  # (the runtime mirror-write plaintext guard is a separate, later concern). This test
  # therefore confirms the END-TO-END guarantee holds — a plaintext sensitive column on
  # a replicant resource IS rejected at compile — while attributing it to ValidateSensitive
  # rather than a (deliberately absent) duplicate replicant verifier. It is GREEN from the
  # start (ValidateSensitive already fires), not a non-vacuity check for a new clause.
  test "a plaintext sensitive column on a replicant resource is rejected at compile (via ValidateSensitive R2)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sensitive]} do
        defmodule Elixir.AshArcadic.Test.ReplicantPlaintextSensitive do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer,
            extensions: [AshArcadic.Replicant]

          arcade do
            client(AshArcadic.Test.MockClient)
            sensitive([:secret])
          end

          replicant do
            source_table("orders")
          end

          attributes do
            uuid_primary_key :id
            attribute :secret, :string
          end

          actions do
            defaults [:read]
          end
        end
      end

    # "binary-storage" is ValidateSensitive R2's wording; this pins attribution to that
    # verifier (the end-to-end guarantee holds even though the replicant slice adds no
    # duplicate check).
    assert err.message =~ "binary-storage"
  end

  # Check 3 — a replicant resource with a create/update/destroy action but NO authorizer
  # leaves ordinary writes ungated, so the effect-once seam-lock (write actions forbidden
  # by default, only the sink bypassing via `authorize?: false`) is absent. A consumer
  # that forgets to gate its mirror action fails at COMPILE, not silently.
  test "a write action with no authorizer leaves the effect-once seam-lock absent => compile error" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:actions]} do
        defmodule Elixir.AshArcadic.Test.ReplicantUnlockedWrite do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer,
            extensions: [AshArcadic.Replicant]

          arcade do
            client(AshArcadic.Test.MockClient)
          end

          replicant do
            source_table("orders")
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:create, :read]
          end
        end
      end

    # "seam-lock" is unique to the replicant write-actions-authorized verifier's message.
    assert err.message =~ "seam-lock"
  end

  # Happy path: absent tenancy (valid — only `:context` is rejected) AND a write action
  # whose resource declares an authorizer (`Ash.Policy.Authorizer` + a forbidding policy =
  # the seam-lock). Compiles clean.
  test "a replicant resource with absent tenancy and an authorized write action compiles clean" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.ReplicantValid do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshArcadic.Replicant]

        arcade do
          client(AshArcadic.Test.MockClient)
        end

        replicant do
          source_table("orders")
          tenant_attribute(:org_id)
        end

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string
        end

        actions do
          defaults [:create, :read]
        end

        policies do
          policy always() do
            forbid_if always()
          end
        end
      end
    end
  end

  # Check 4 (T3-review-driven) — a `sensitive` PRIMARY KEY. `Resolver.pk_values/2` builds the
  # mirror identity from the source row's PLAINTEXT key columns and does NOT pass them through
  # the F5 sensitive-halt (the identity must be plaintext to MATCH). A `:binary` PK marked
  # `sensitive` passes ValidateSensitive R2 (it IS binary-storage-typed), so only this verifier
  # catches it — the sink would otherwise write the plaintext source PK into a classified column
  # AND break idempotent matching. Mirrors R3 (the tenant discriminator, another plaintext
  # selector, cannot be sensitive).
  test "a sensitive primary key on a replicant resource leaks the plaintext identity => compile error" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:arcade, :sensitive]} do
        defmodule Elixir.AshArcadic.Test.ReplicantSensitivePk do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer,
            extensions: [AshArcadic.Replicant]

          arcade do
            client(AshArcadic.Test.MockClient)
            # `:binary` => passes ValidateSensitive R2 (binary-storage-typed), so this
            # resource is caught ONLY by the primary-key-not-sensitive verifier.
            sensitive([:id])
          end

          replicant do
            source_table("orders")
          end

          attributes do
            attribute :id, :binary do
              primary_key?(true)
              allow_nil?(false)
            end
          end

          actions do
            defaults [:read]
          end
        end
      end

    # "primary-key attribute" is unique to the primary-key-not-sensitive verifier's message
    # (distinguishes it from R2's "binary-storage" wording).
    assert err.message =~ "primary-key attribute"
  end

  # Check 5 — a primary-key column in the replicant `skip` list. `reject_empty_identity!`
  # checks the RAW source record carries the PK, but `Resolver.attrs_for_upsert/2` then DROPS
  # every `skip`-listed column from the write inputs — so a skipped PK passes the raw check yet
  # never reaches the create, leaving `Ash.create!(upsert?: true)` without the identity: a UUID
  # PK gets a fresh random value each apply (duplicate vertices; deletes can't find them). The
  # PK source column maps 1:1 to its attribute (no rename), so this is statically decidable and
  # fails closed at compile.
  test "a primary-key column in the replicant skip list breaks the mirror identity => compile error" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :skip]} do
        defmodule Elixir.AshArcadic.Test.ReplicantSkippedPk do
          use Ash.Resource,
            domain: AshArcadic.Test.Domain,
            validate_domain_inclusion?: false,
            data_layer: AshArcadic.DataLayer,
            extensions: [AshArcadic.Replicant]

          arcade do
            client(AshArcadic.Test.MockClient)
          end

          replicant do
            source_table("orders")
            skip([:id])
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end
        end
      end

    # "must not be in the replicant `skip`" is unique to the primary-key-not-skipped verifier.
    assert err.message =~ "must not be in the replicant `skip`"
  end

  # A read-only replicant resource (no write actions) with no authorizer is valid — check 3
  # must pass VACUOUSLY (nothing to seam-lock). This guards T1's read-only fixtures.
  test "a read-only replicant resource with no authorizer compiles clean (check 3 is vacuous)" do
    refute_dsl_errors do
      defmodule Elixir.AshArcadic.Test.ReplicantReadOnly do
        use Ash.Resource,
          domain: AshArcadic.Test.Domain,
          validate_domain_inclusion?: false,
          data_layer: AshArcadic.DataLayer,
          extensions: [AshArcadic.Replicant]

        arcade do
          client(AshArcadic.Test.MockClient)
        end

        replicant do
          source_table("orders")
        end

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end
      end
    end
  end
end
