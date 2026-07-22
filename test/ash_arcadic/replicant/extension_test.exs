defmodule AshArcadic.Replicant.ExtensionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AshArcadic.Replicant.Info

  # Minimal in-test graph resource declaring every `replicant do ... end` option.
  defmodule Elixir.AshArcadic.Test.ReplicantFullyDeclared do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant]

    arcade do
      client(AshArcadic.Test.MockClient)
    end

    replicant do
      source_schema("app")
      source_table("orders")
      tenant_attribute(:org_id)
      skip([:internal_notes])
      on_truncate(:mirror)
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  # Minimal in-test graph resource declaring only the required `source_table` —
  # exercises every default (`source_schema` -> "public", `on_truncate` -> :halt,
  # `skip` -> [], `tenant_attribute` -> nil).
  defmodule Elixir.AshArcadic.Test.ReplicantDefaultsOnly do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Domain,
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

  alias AshArcadic.Test.ReplicantDefaultsOnly
  alias AshArcadic.Test.ReplicantFullyDeclared

  describe "declared values" do
    test "Info returns every declared replicant option" do
      assert Info.source_schema(ReplicantFullyDeclared) == "app"
      assert Info.source_table(ReplicantFullyDeclared) == "orders"
      assert Info.tenant_attribute(ReplicantFullyDeclared) == :org_id
      assert Info.skip(ReplicantFullyDeclared) == [:internal_notes]
      assert Info.on_truncate(ReplicantFullyDeclared) == :mirror
    end
  end

  describe "defaults" do
    test "source_schema defaults to \"public\" when unset" do
      assert Info.source_schema(ReplicantDefaultsOnly) == "public"
    end

    test "on_truncate defaults to :halt when unset" do
      assert Info.on_truncate(ReplicantDefaultsOnly) == :halt
    end

    test "skip defaults to [] when unset" do
      assert Info.skip(ReplicantDefaultsOnly) == []
    end

    test "source_table has no reflection fallback -- returns the declared value" do
      assert Info.source_table(ReplicantDefaultsOnly) == "widgets"
    end

    test "tenant_attribute is nil when unset" do
      assert Info.tenant_attribute(ReplicantDefaultsOnly) == nil
    end
  end
end
