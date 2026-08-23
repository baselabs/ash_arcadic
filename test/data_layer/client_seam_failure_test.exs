defmodule AshArcadic.DataLayer.ClientSeamFailureTest do
  @moduledoc """
  Failure modes of the HOST-supplied `AshArcadic.Client` seam (carried item R9):
  a client whose `conn/0` RAISES, and one that returns an invalid conn (not an
  `%Arcadic.Conn{}`). The contract under test is FAIL-CLOSED LOUD: a broken host
  client must crash the action — never quietly fall back to some default
  connection (which would aim the action at the wrong database) and never embed
  the host exception's payload into a data-layer error.

  The invalid-conn rejection is enforced by the STRUCT GUARDS downstream of the
  seam (`AshArcadic.Transaction.resolve_conn/2`'s `%Conn{}` pattern,
  `Arcadic.with_database/2`): a non-conn term dies as a FunctionClauseError
  before any wire call. Through an Ash action both failures surface as
  `Ash.Error.Unknown` — Ash's standard wrapper for a data-layer callback
  exception — with the original exception nested and attributed ("Exception
  raised in: <resource>.<action>"). That nested host text is the host's own
  module and message (Ash's behavior, host-owned); the data layer's job — pinned
  here — is to neither swallow the failure nor fall back to any default
  connection (which would aim the action at the wrong database).
  """

  use ExUnit.Case, async: true

  alias AshArcadic.DataLayer.ClientSeamFailureTest.{BadConnDoc, RaisingDoc}

  defmodule RaisingClient do
    @moduledoc false
    @behaviour AshArcadic.Client
    @impl true
    def conn, do: raise("host client boom SNT_host_boom_x3")
  end

  defmodule InvalidConnClient do
    @moduledoc false
    @behaviour AshArcadic.Client
    @impl true
    def conn, do: {:ok, "http://localhost:2480"}
  end

  defmodule RaisingDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.DataLayer.ClientSeamFailureTest.RaisingClient)
      label(:ClientFailRaising)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:name]
      defaults [:read, :create]
    end
  end

  defmodule BadConnDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.DataLayer.ClientSeamFailureTest.InvalidConnClient)
      label(:ClientFailBadConn)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:name]
      defaults [:read, :create]
    end
  end

  describe "a client whose conn/0 raises" do
    test "the action fails loud with the host exception nested (never swallowed, never silent)" do
      assert_raise Ash.Error.Unknown, ~r/host client boom SNT_host_boom_x3/, fn ->
        Ash.read(RaisingDoc)
      end
    end

    test "same on the write path (create), loud" do
      assert_raise Ash.Error.Unknown, ~r/host client boom/, fn ->
        RaisingDoc
        |> Ash.Changeset.for_create(:create, %{name: "x"})
        |> Ash.create()
      end
    end
  end

  describe "a client returning an invalid conn (not %Arcadic.Conn{})" do
    test "a read fails closed LOUD at the struct guard — never a fallback connection" do
      assert_raise Ash.Error.Unknown, ~r/FunctionClauseError.*resolve_conn/is, fn ->
        Ash.read(BadConnDoc)
      end
    end

    test "a create fails closed LOUD the same way" do
      assert_raise Ash.Error.Unknown, ~r/FunctionClauseError.*resolve_conn/is, fn ->
        BadConnDoc
        |> Ash.Changeset.for_create(:create, %{name: "x"})
        |> Ash.create()
      end
    end
  end
end
