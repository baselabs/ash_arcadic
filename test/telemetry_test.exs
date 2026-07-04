defmodule AshArcadic.TelemetryTest do
  use ExUnit.Case, async: true
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
end
