defmodule AshArcadic.DataLayer.ConnectionFailureRedactionTest do
  @moduledoc """
  The refused-connection failure class driven through real Ash actions against a real
  (dead) socket — no server, no stub: the data layer dials 127.0.0.1:9, Req/Mint yield
  a genuine `:econnrefused`, and the error an Ash caller receives must be value-free
  (AGENTS.md Critical Rule 4). This is the driven complement to `redact_db_error_test.exs`
  (structural unit asserts on the mapper): it proves the WHOLE path — Ash action →
  data layer → Arcadic HTTP transport → real POST → `%TransportError{reason: :econnrefused}`
  → redacted Query/CreateFailed wrap — not just the mapper's shape.

  The sentinel values (URL, database name, password, filter/create attribute value) ride
  the exact places a redaction regression would echo: the conn, the request, and the
  params. A leak of any of them into the error message, its inspect, or the logs reds
  these tests.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  require Ash.Query

  alias AshArcadic.DataLayer.ConnectionFailureRedactionTest.DeadPortClient
  alias AshArcadic.DataLayer.ConnectionFailureRedactionTest.DeadPortDoc

  defmodule DeadPortClient do
    @moduledoc false
    @behaviour AshArcadic.Client

    @url "http://127.0.0.1:9"
    @db "s3nt1nel_deadport_db"
    @pw "SNT_dead_pw_x92"

    @doc "Every conn-derived value a redaction regression could echo."
    def sentinels, do: [@url, @db, @pw]

    @impl true
    def conn, do: Arcadic.connect(@url, @db, auth: {"root", @pw})
  end

  defmodule DeadPortDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.DataLayer.ConnectionFailureRedactionTest.DeadPortClient)
      label(:FailureDoc)
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

  @value_sentinel "SNT_row_value_x77"
  @leaks DeadPortClient.sentinels() ++ [@value_sentinel]

  # A transport whose session lifecycle succeeds but every command fails — drives the
  # write_command ERROR arm of do_create (data_layer.ex:1946) through a real Ash.create:
  # BEGIN opens the scripted session, the CREATE itself fails. Without this, every
  # driven write failure dies at BEGIN (the refused/401/500 classes) and the command
  # redaction wrap is never reached through an action.
  defmodule CommandFailTransport do
    @moduledoc false
    @behaviour Arcadic.Transport

    @impl true
    def begin(_conn, _opts), do: {:ok, "script-session"}

    @impl true
    def commit(_conn), do: :ok

    @impl true
    def rollback(_conn), do: :ok

    @impl true
    def execute(_conn, _mode, _request, _opts),
      do: {:error, %Arcadic.TransportError{reason: :closed}}
  end

  defmodule CommandFailClient do
    @moduledoc false
    @behaviour AshArcadic.Client

    @url "http://scripted.invalid"
    @db "s3nt1nel_cmdfail_db"
    @pw "SNT_cmd_pw_x51"

    def sentinels, do: [@url, @db, @pw]

    @impl true
    def conn,
      do:
        Arcadic.connect(@url, @db,
          auth: {"root", @pw},
          transport: CommandFailTransport
        )
  end

  defmodule CommandFailDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.DataLayer.ConnectionFailureRedactionTest.CommandFailClient)
      label(:CmdFailDoc)
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

  describe "a refused connection through a read" do
    test "surfaces a redacted QueryFailed — reason class only, no conn/request values" do
      query = Ash.Query.filter(DeadPortDoc, name == ^@value_sentinel)

      assert {:error, error} = Ash.read(query)

      assert Enum.any?(error.errors, &match?(%AshArcadic.Errors.QueryFailed{}, &1)),
             "expected the failure to surface as a QueryFailed, got: #{inspect(error.errors)}"

      # The exact redaction contract: the transport reason atom, nothing else.
      assert Exception.message(error) =~ "ArcadeDB transport error (econnrefused)"

      for leak <- @leaks do
        refute Exception.message(error) =~ leak
        refute inspect(error) =~ leak
      end

      # The Cypher statement itself is a Rule-4 payload — it must never ride the error.
      refute Exception.message(error) =~ "MATCH"
    end

    test "leaves the logs value-free (no URL, db name, credential, or Cypher)" do
      query = Ash.Query.filter(DeadPortDoc, name == ^@value_sentinel)

      {result, log} = with_log(fn -> Ash.read(query) end)

      assert {:error, _} = result

      for leak <- @leaks ++ ["MATCH"] do
        refute log =~ leak
      end
    end
  end

  describe "a refused connection through a create" do
    # Ash wraps creates in a data-layer transaction (can?(:transact)), so the first write
    # OPENs a session: the refused conn dies at BEGIN, and open_session/1 deliberately
    # collapses the transport error to the value-free :transaction_begin_failed atom
    # (transaction.ex: "we never carry a database name or transport error text out").
    # The driven contract for writes is therefore the STATIC begin-failure reason —
    # value-free by construction; the transport reason class is surfaced on the READ
    # tier (no session involved). Substring-matched so a future value-free enrichment
    # (e.g. appending the reason atom) still passes.
    test "surfaces the static begin-failure CreateFailed — no props, Cypher, or conn values" do
      assert {:error, error} =
               DeadPortDoc
               |> Ash.Changeset.for_create(:create, %{name: @value_sentinel})
               |> Ash.create()

      assert Enum.any?(error.errors, &match?(%AshArcadic.Errors.CreateFailed{}, &1)),
             "expected the failure to surface as a CreateFailed, got: #{inspect(error.errors)}"

      assert Exception.message(error) =~ "could not begin ArcadeDB transaction"

      for leak <- @leaks do
        refute Exception.message(error) =~ leak
        refute inspect(error) =~ leak
      end

      # The write statement (CREATE … $props) is a Rule-4 payload.
      refute Exception.message(error) =~ "CREATE ("
    end
  end

  describe "a command failure after a successful session begin" do
    test "surfaces the redacted transport reason — the command wrap never echoes the write" do
      assert {:error, error} =
               CommandFailDoc
               |> Ash.Changeset.for_create(:create, %{name: @value_sentinel})
               |> Ash.create()

      assert Enum.any?(error.errors, &match?(%AshArcadic.Errors.CreateFailed{}, &1)),
             "expected the failure to surface as a CreateFailed, got: #{inspect(error.errors)}"

      assert Exception.message(error) =~ "ArcadeDB transport error (closed)"

      for leak <- CommandFailClient.sentinels() ++ [@value_sentinel] do
        refute Exception.message(error) =~ leak
        refute inspect(error) =~ leak
      end

      refute Exception.message(error) =~ "CREATE ("
    end
  end
end
