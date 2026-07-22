defmodule AshArcadic.Replicant.ResolverTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AshArcadic.Replicant.Error
  alias AshArcadic.Replicant.Resolver

  # --- Fixtures: replicant mirror resources + domains that statically list them ---
  # (`build_index/1` reflects `Ash.Domain.Info.resources/1`, so its resources must be
  # declared on a domain that returns them; the tenant/skip/sensitive fixtures are read
  # directly by the pure resolver and live on the unregistered `AshArcadic.Test.Domain`.)

  defmodule Elixir.AshArcadic.Test.Replicant.OrdersMirror do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.MirrorIndexDomain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer,
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
      attribute :name, :string
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Elixir.AshArcadic.Test.Replicant.WidgetsMirror do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.MirrorIndexDomain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant]

    arcade do
      client(AshArcadic.Test.MockClient)
    end

    replicant do
      source_table("widgets")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Elixir.AshArcadic.Test.Replicant.MirrorIndexDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshArcadic.Test.Replicant.OrdersMirror
      resource AshArcadic.Test.Replicant.WidgetsMirror
    end
  end

  # Two mirrors claiming the SAME `{public, orders}` source — the F9 duplicate-source
  # ambiguity build_index/1 must fail closed on.
  defmodule Elixir.AshArcadic.Test.Replicant.OrdersDupA do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.DuplicateSourceDomain,
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

  defmodule Elixir.AshArcadic.Test.Replicant.OrdersDupB do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.DuplicateSourceDomain,
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

  defmodule Elixir.AshArcadic.Test.Replicant.DuplicateSourceDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshArcadic.Test.Replicant.OrdersDupA
      resource AshArcadic.Test.Replicant.OrdersDupB
    end
  end

  # A `sensitive` (binary-storage) target column NOT in the replicant skip list —
  # the F5 tripwire fixture. ValidateSensitive R2 forces `:secret` to be :binary.
  defmodule Elixir.AshArcadic.Test.Replicant.PeopleSensitiveMirror do
    @moduledoc false
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
      source_table("people")
      tenant_attribute(:org_id)
    end

    attributes do
      uuid_primary_key :id
      attribute :org_id, :string
      attribute :secret, :binary
    end

    actions do
      defaults [:read]
    end
  end

  # A `sensitive` target column that IS in the replicant skip list — the documented
  # safe config: skip wins, so the F5 guard must NOT halt.
  defmodule Elixir.AshArcadic.Test.Replicant.PeopleSensitiveSkippedMirror do
    @moduledoc false
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
      source_table("people_skipped")
      skip([:secret])
    end

    attributes do
      uuid_primary_key :id
      attribute :org_id, :string
      attribute :secret, :binary
    end

    actions do
      defaults [:read]
    end
  end

  # Replicant `skip` list + a TOASTable `:bio` column absent from the record.
  defmodule Elixir.AshArcadic.Test.Replicant.NotesSkipMirror do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant]

    arcade do
      client(AshArcadic.Test.MockClient)
    end

    replicant do
      source_table("notes")
      skip([:internal_notes])
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string
      attribute :internal_notes, :string
      attribute :bio, :string
    end

    actions do
      defaults [:read]
    end
  end

  alias AshArcadic.Test.Replicant.DuplicateSourceDomain
  alias AshArcadic.Test.Replicant.MirrorIndexDomain
  alias AshArcadic.Test.Replicant.NotesSkipMirror
  alias AshArcadic.Test.Replicant.OrdersMirror
  alias AshArcadic.Test.Replicant.PeopleSensitiveMirror
  alias AshArcadic.Test.Replicant.PeopleSensitiveSkippedMirror
  alias AshArcadic.Test.Replicant.WidgetsMirror

  describe "build_index/1" do
    test "maps distinct sources to their mirror resources" do
      assert {:ok, index} = Resolver.build_index([MirrorIndexDomain])
      assert index[{"public", "orders"}] == OrdersMirror
      assert index[{"public", "widgets"}] == WidgetsMirror
      assert map_size(index) == 2
    end

    # F9 — the plan-review's added check. Two mirrors claiming one source is an
    # ambiguous route; build_index/1 fails closed with the exact tuple.
    test "fails closed on a duplicate source (F9)" do
      assert Resolver.build_index([DuplicateSourceDomain]) ==
               {:error, {:duplicate_source, {"public", "orders"}}}
    end

    # NOTE on the precedent's `{:missing_source_table, resource}` arm: in ash_arcadic
    # `source_table` is DSL `required: true` (lib/ash_arcadic/replicant.ex), so
    # `Info.replicant_source_table/1` never returns `:error` for a compiled resource
    # and the arm is compile-prevented — it cannot be driven RED by a real resource.
    # It is retained in build_index/1 as fail-closed complete-union handling of the
    # `{:ok, _} | :error` accessor. The invariant is enforced EARLIER (at compile) than
    # the precedent's runtime guard.
  end

  describe "lookup/3" do
    test "applies the nil-schema -> \"public\" default and returns nil for an unmapped table" do
      {:ok, index} = Resolver.build_index([MirrorIndexDomain])
      assert Resolver.lookup(index, nil, "orders") == OrdersMirror
      assert Resolver.lookup(index, "public", "orders") == OrdersMirror
      assert Resolver.lookup(index, "public", "does_not_exist") == nil
    end
  end

  describe "resolve_tenant!/3 — the fail-closed trio (nil / false / blank)" do
    test "raises :tenant_required when the tenant column is absent" do
      err =
        assert_raise Error, fn ->
          Resolver.resolve_tenant!(OrdersMirror, %{"id" => "row-1"}, :upsert)
        end

      assert err.reason == :tenant_required
      assert err.resource == OrdersMirror
      assert err.op == :upsert
    end

    # `false` is load-bearing: Ash treats a falsy tenant as UNSCOPED
    # (`handle_attribute_multitenancy` guards `if changeset.tenant`), so a `false`
    # tenant would land the mirror write unscoped. Fail closed exactly like nil.
    # RED against a guard that only checks nil (present_or_required lets `false` pass).
    test "raises :tenant_required on a false tenant" do
      err =
        assert_raise Error, fn ->
          Resolver.resolve_tenant!(OrdersMirror, %{"id" => "row-1", "org_id" => false}, :upsert)
        end

      assert err.reason == :tenant_required
    end

    # RED against a nil-only guard (a blank string is present but scopes nothing).
    test "raises :tenant_required on a blank-string tenant" do
      err =
        assert_raise Error, fn ->
          Resolver.resolve_tenant!(OrdersMirror, %{"id" => "row-1", "org_id" => "   "}, :upsert)
        end

      assert err.reason == :tenant_required
    end

    test "returns the tenant for a present value" do
      assert Resolver.resolve_tenant!(OrdersMirror, %{"org_id" => "acme"}, :upsert) == "acme"
    end

    test "returns nil when the resource declares no tenant_attribute" do
      assert Resolver.resolve_tenant!(WidgetsMirror, %{"id" => "w-1"}, :upsert) == nil
    end
  end

  describe "resolve_tenant!/3 — cross-tenant fabrication" do
    # Fabricate a FOREIGN-tenant source record — the attacker's OWN tenant value —
    # and assert resolve_tenant! yields exactly that, never an ambient/loaded tenant
    # (feedback_cross_tenant_test_fabricates_attacker_not_reuses_loaded).
    test "yields the record's own (attacker) tenant, never an ambient one" do
      attacker = %{"id" => "row-1", "org_id" => "attacker-org", "name" => "Mallory"}
      assert Resolver.resolve_tenant!(OrdersMirror, attacker, :upsert) == "attacker-org"
    end
  end

  describe "resolve_tenant!/3 — value-free error (positive control)" do
    test "the raised error carries no row data in its message or fields" do
      # A row carrying a distinctive secret-shaped value but NO tenant column.
      record = %{"id" => "row-1", "ssn" => "999-99-9999", "note" => "board-minutes"}

      err =
        assert_raise Error, fn -> Resolver.resolve_tenant!(OrdersMirror, record, :upsert) end

      message = Exception.message(err)
      refute message =~ "999-99-9999"
      refute message =~ "board-minutes"
      # No exception field holds the record itself.
      refute err |> Map.from_struct() |> Map.values() |> Enum.member?(record)
    end
  end

  describe "attrs_for_upsert/2" do
    test "drops replicant-skip cols; unchanged-TOAST cols (absent from record) are excluded" do
      # `:internal_notes` is skipped; `:bio` is a declared TOASTable attr ABSENT from
      # the record (an unchanged-TOAST UPDATE never puts it in `record`).
      record = %{"id" => "n-1", "name" => "Ada", "internal_notes" => "do-not-mirror"}

      {inputs, fields} = Resolver.attrs_for_upsert(NotesSkipMirror, record)

      assert inputs == %{id: "n-1", name: "Ada"}
      assert Enum.sort(fields) == [:id, :name]
      refute Map.has_key?(inputs, :internal_notes)
      refute Map.has_key?(inputs, :bio)
    end

    # F5 tripwire — a plaintext value mapped to a `sensitive`, non-skipped target must
    # HALT value-free (never reach the write). RED against a guardless mapping: without
    # the F5 guard the plaintext flows straight into `inputs`.
    test "HALTS value-free on a plaintext value bound for a sensitive target (F5)" do
      record = %{
        "id" => "p-1",
        "org_id" => "acme",
        "secret" => "top-secret-plaintext-ssn"
      }

      err =
        assert_raise Error, fn -> Resolver.attrs_for_upsert(PeopleSensitiveMirror, record) end

      assert err.reason == :sensitive_plaintext
      assert err.resource == PeopleSensitiveMirror
      # Value-free: the refused plaintext never appears in the error.
      refute Exception.message(err) =~ "top-secret-plaintext-ssn"
      refute err |> Map.from_struct() |> Map.values() |> Enum.member?("top-secret-plaintext-ssn")
    end

    # Skip wins over the F5 halt: a sensitive column listed in replicant `skip` is the
    # documented safe config and must be dropped, not halted.
    test "a sensitive column in replicant skip is dropped, not halted (skip wins)" do
      record = %{"id" => "p-1", "org_id" => "acme", "secret" => "whatever"}

      {inputs, _fields} = Resolver.attrs_for_upsert(PeopleSensitiveSkippedMirror, record)

      assert inputs == %{id: "p-1", org_id: "acme"}
      refute Map.has_key?(inputs, :secret)
    end
  end

  describe "writable_target/2 (shares the classify guard with attrs_for_upsert/2)" do
    test "maps a declared column to its target atom, skips undeclared/skip columns" do
      assert Resolver.writable_target(OrdersMirror, "name") == {:ok, :name}
      assert Resolver.writable_target(OrdersMirror, "not_a_column") == :skip
      assert Resolver.writable_target(NotesSkipMirror, "internal_notes") == :skip
    end

    # F5 fires symmetrically from the single-column entry point, not just the bulk one.
    test "HALTS value-free on a sensitive, non-skipped target column (F5 symmetry)" do
      err =
        assert_raise Error, fn -> Resolver.writable_target(PeopleSensitiveMirror, "secret") end

      assert err.reason == :sensitive_plaintext
    end
  end

  describe "primary_key/1 and pk_values/2" do
    test "primary_key returns the resource primary key" do
      assert Resolver.primary_key(OrdersMirror) == [:id]
    end

    test "pk_values reads the string-keyed primary key from the record" do
      assert Resolver.pk_values(OrdersMirror, %{"id" => "row-1", "org_id" => "acme"}) ==
               %{id: "row-1"}
    end
  end
end
