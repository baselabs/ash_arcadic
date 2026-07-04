defmodule AshArcadic.MultitenancyTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Multitenancy

  # A minimal resource with no tenant_database MFA exercises the default encoder.
  defmodule Res do
    use Ash.Resource, domain: nil, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
    end

    attributes do
      uuid_primary_key :id
    end

    multitenancy do
      strategy :context
    end
  end

  # Dispatches on the tenant so one resource exercises every validate_mfa! outcome.
  defmodule TenantDb do
    @moduledoc false
    # valid chars but > 128 bytes
    def db("toolong"), do: String.duplicate("a", 200)
    # invalid identifier (not letter-first/charset)
    def db("badident"), do: "bad;name"
    # non-binary return
    def db("nonbinary"), do: :not_a_string
    # valid
    def db(tenant), do: "db_" <> to_string(tenant)
  end

  # Mirrors `Res` plus a `tenant_database` MFA — exercises the validate_mfa! path.
  defmodule ResMfa do
    use Ash.Resource, domain: nil, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
      tenant_database({TenantDb, :db, []})
    end

    attributes do
      uuid_primary_key :id
    end

    multitenancy do
      strategy :context
    end
  end

  test "passthrough for identifier-body-clean tenants (readable ULID/slug/integer)" do
    assert Multitenancy.database_name(Res, "acme") == "t_acme"
    assert Multitenancy.database_name(Res, "01HZX") == "t_01HZX"
    assert Multitenancy.database_name(Res, 42) == "t_42"
  end

  test "base32 branch for non-clean tenants (UUID with hyphens)" do
    name = Multitenancy.database_name(Res, "a1b2-c3d4")
    assert String.starts_with?(name, "g")
    assert Arcadic.Identifier.valid?(name)
  end

  test "branches are disjoint (injective): t-prefix vs g-prefix never collide" do
    refute Multitenancy.database_name(Res, "acme") == Multitenancy.database_name(Res, "a-c-m-e")
  end

  test "blank tenant fails closed, value-free" do
    assert_raise ArgumentError, fn -> Multitenancy.database_name(Res, "") end
  end

  test "an overflow tenant (> 128 bytes after encoding) fails closed WITHOUT echoing the value" do
    huge = String.duplicate("z", 200)
    err = assert_raise ArgumentError, fn -> Multitenancy.database_name(Res, huge) end
    refute err.message =~ "zzz"
  end

  test "128-byte boundary is inclusive: a passthrough of exactly 128 bytes is accepted" do
    # "t_" (2 bytes) + 126 bytes = exactly 128 → accepted (catches an off-by-one if <= became <)
    str = String.duplicate("a", 126)
    name = Multitenancy.database_name(Res, str)
    assert name == "t_" <> str
    assert byte_size(name) == 128
    assert Arcadic.Identifier.valid?(name)

    # One byte longer: "t_" + 127 = 129 → passthrough is rejected and falls through to
    # base32, whose encoding of a 127-byte input is itself > 128 bytes → fails closed.
    over = String.duplicate("a", 127)
    assert_raise ArgumentError, fn -> Multitenancy.database_name(Res, over) end
  end

  test "tenant_database MFA: a valid returned identifier is used" do
    assert Multitenancy.database_name(ResMfa, "acme") == "db_acme"
  end

  test "tenant_database MFA: an invalid identifier return fails closed, value-free" do
    assert_raise ArgumentError, fn -> Multitenancy.database_name(ResMfa, "badident") end
  end

  test "tenant_database MFA: a too-long return fails closed WITHOUT echoing the value" do
    err = assert_raise ArgumentError, fn -> Multitenancy.database_name(ResMfa, "toolong") end
    refute err.message =~ "aaa"
  end

  test "tenant_database MFA: a non-binary return fails closed, value-free" do
    assert_raise ArgumentError, fn -> Multitenancy.database_name(ResMfa, "nonbinary") end
  end

  test "a non-String.Chars tenant (map/tuple/struct) fails closed value-free, never leaking the term" do
    # to_string/1 on a non-String.Chars term raises Protocol.UndefinedError whose message
    # embeds the term (a Rule-4 value leak). The encoder must fail closed with a value-free
    # ArgumentError instead — the same posture as the blank/overflow paths.
    err = assert_raise ArgumentError, fn -> Multitenancy.database_name(Res, %{secret: "hunter2"}) end
    refute err.message =~ "hunter2"
    refute err.message =~ "secret"

    assert_raise ArgumentError, fn -> Multitenancy.database_name(Res, {:a, :b}) end
  end
end
