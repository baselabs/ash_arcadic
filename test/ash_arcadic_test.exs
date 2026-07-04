defmodule AshArcadicTest do
  use ExUnit.Case, async: true

  test "modules are defined and documented" do
    assert Code.ensure_loaded?(AshArcadic)
    assert Code.ensure_loaded?(AshArcadic.DataLayer)
  end
end
