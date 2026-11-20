defmodule AshArcadic.OptionalCDCTest do
  use ExUnit.Case, async: true

  test "the CDC implementation is available exactly when the optional transport is declared" do
    declared? = Enum.any?(Mix.Project.config()[:deps], &(elem(&1, 0) == :replicant))

    assert Code.ensure_loaded?(Replicant.Sink) == declared?

    for module <- [
          AshArcadic.Replicant.Apply,
          AshArcadic.Replicant.Sink.Impl,
          AshArcadic.Replicant.Pipeline
        ] do
      assert Code.ensure_loaded?(module) == declared?, inspect(module)
    end
  end
end
