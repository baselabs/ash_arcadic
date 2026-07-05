defmodule AshArcadic.TelemetryTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Changes.CreateEdge
  alias AshArcadic.Telemetry

  test "span runs the fun and returns its result; emits [:ash_arcadic, op] events" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ash_arcadic, :read, :stop]])

    result =
      Telemetry.span(:read, %{resource: Foo, multitenancy: :attribute}, fn ->
        {{:ok, []}, %{row_count: 0, result: :ok}}
      end)

    assert result == {:ok, []}
    assert_received {[:ash_arcadic, :read, :stop], ^ref, _measurements, _meta}
  end

  test "an off-allowlist metadata key raises (no tenant-derived value in telemetry)" do
    assert_raise ArgumentError, ~r/allowlist/, fn ->
      Telemetry.span(:read, %{database: "t_acme"}, fn -> {{:ok, []}, %{}} end)
    end
  end

  test "an off-allowlist key in STOP metadata also raises (stop-side Rule 4 backstop)" do
    assert_raise ArgumentError, ~r/allowlist/, fn ->
      Telemetry.span(:read, %{resource: Foo}, fn -> {{:ok, []}, %{database: "t_acme"}} end)
    end
  end

  test "result_tag maps returns to :ok | :error" do
    assert Telemetry.result_tag({:error, :x}) == :error
    assert Telemetry.result_tag({:ok, []}) == :ok
  end

  test "properties? is on the value-free allowlist (create_edge metadata)" do
    assert :properties? in AshArcadic.Telemetry.allowed_meta_keys()

    assert AshArcadic.Telemetry.validate!(%{resource: Foo, properties?: true}) ==
             %{resource: Foo, properties?: true}
  end

  test "the create_edge span emits in_transaction? in its stop metadata (spec §9)" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ash_arcadic, :create_edge, :stop]])

    # Drive CreateEdge.run through the R4-error path (plaintext sensitive prop, empty
    # `to:`) so the span emits its stop metadata WITHOUT needing a live DB.
    cs = %Ash.Changeset{
      resource: AshArcadic.Test.EdgeSensitivePerson,
      arguments: %{secret: "plaintext"},
      action: %{arguments: [%{name: :secret, type: Ash.Type.String, constraints: []}]},
      to_tenant: nil
    }

    assert {:error, _} = CreateEdge.run(cs, %{}, edge: :links, to: :to)

    assert_received {[:ash_arcadic, :create_edge, :stop], ^ref, _measurements, meta}
    assert Map.has_key?(meta, :in_transaction?)
    assert is_boolean(meta.in_transaction?)
  end
end
