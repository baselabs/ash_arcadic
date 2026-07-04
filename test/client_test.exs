defmodule AshArcadic.ClientTest do
  use ExUnit.Case, async: true

  alias AshArcadic.Test.MockClient

  test "a client module returns an Arcadic.Conn" do
    assert %Arcadic.Conn{database: "ash_arcadic_test"} = MockClient.conn()
  end

  test "the behaviour declares conn/0" do
    assert Enum.member?(AshArcadic.Client.behaviour_info(:callbacks), {:conn, 0})
  end
end
