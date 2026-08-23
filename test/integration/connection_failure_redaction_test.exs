defmodule AshArcadic.Integration.ConnectionFailureRedactionTest do
  @moduledoc """
  The credential-failure and non-MVCC 5xx classes driven through real Ash actions
  against the REAL pinned ArcadeDB (26.8.1) — live-substrate tier of the R6 driven
  redaction tests (`test/data_layer/connection_failure_redaction_test.exs` is the
  no-server refused-conn tier). Asserts the error an Ash caller receives is value-free
  (AGENTS.md Critical Rule 4): server `error`/`detail` text, the credential, and the
  database NAME (tenant-derived on :context resources — the primary `detail` leak
  vector) must never surface.

  Response bodies are LIVE-PROBED on the pinned image (this slice, throwaway
  container — not self-signed):

  - bad Basic credentials → 403 `{"error":"Security error","requestId":…,
    "exception":"com.arcadedb.server.security.ServerSecurityException",
    "detail":"User/Password not valid"}` → arcadic reason `:unauthorized`.
  - conn to a never-created database → 500 `{"error":"Internal error","requestId":…,
    "exception":"com.arcadedb.exception.DatabaseOperationException","detail":
    "Database '<name>' is not available"}` → `:database_not_found`; the detail
    carries the database name.

  A true 401 (no Authorization header) is unreachable through this stack —
  `Arcadic.connect/3` mandates `:auth`, so the drivable credential-failure class is
  the 403. (The probed no-header 401 body `{"error":"","requestId":…}` carries no
  exception FQN and maps to arcadic's generic `:server_error` fallback — arcadic's
  own `Error.from_response/2` unit tier covers that mapping.)

  Write-tier note: Ash wraps creates in a data-layer transaction, so a credential or
  500 failure on the session BEGIN collapses to the static value-free
  "could not begin ArcadeDB transaction" (see the unit tier's create test); the live
  write tests here pin that collapse against real bodies and guard the begin path's
  logs (an `%Arcadic.Error{}` begin failure carries quarantined `message`/`detail`
  fields a logging regression could echo).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :integration

  defmodule BadCredsClient do
    @moduledoc false
    @behaviour AshArcadic.Client

    @db "s3nt1nel_authfail_db"
    @pw "SNT_wrong_pw_x93"

    def sentinels, do: [@db, @pw]

    @impl true
    def conn,
      do: Arcadic.connect(System.fetch_env!("ARCADIC_TEST_URL"), @db, auth: {"root", @pw})
  end

  defmodule AbsentDbClient do
    @moduledoc false
    @behaviour AshArcadic.Client

    @db "s3nt1nel_absent_db"

    def sentinels, do: [@db]

    @impl true
    def conn do
      pass = System.get_env("ARCADIC_TEST_PASSWORD", "arcadedb_dev_password")
      Arcadic.connect(System.fetch_env!("ARCADIC_TEST_URL"), @db, auth: {"root", pass})
    end
  end

  defmodule BadCredsDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Integration.ConnectionFailureRedactionTest.BadCredsClient)
      label(:AuthFailDoc)
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

  defmodule AbsentDbDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Integration.ConnectionFailureRedactionTest.AbsentDbClient)
      label(:AbsentDbDoc)
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

  describe "bad credentials (live 403 ServerSecurityException) through a read" do
    test "surfaces the unauthorized reason class only — no server text or credential" do
      assert {:error, error} = Ash.read(BadCredsDoc)

      assert Enum.any?(error.errors, &match?(%AshArcadic.Errors.QueryFailed{}, &1)),
             "expected the failure to surface as a QueryFailed, got: #{inspect(error.errors)}"

      assert Exception.message(error) =~ "ArcadeDB error (unauthorized)"

      # The probed 403 body's error/detail text is the leak vector on this class.
      for leak <- BadCredsClient.sentinels() ++ ["root", "Security error", "not valid"] do
        refute Exception.message(error) =~ leak
        refute inspect(error) =~ leak
      end
    end
  end

  describe "a never-created database (live 500 DatabaseOperationException) through a read" do
    test "surfaces the database_not_found reason class only — the detail's db name never rides" do
      assert {:error, error} = Ash.read(AbsentDbDoc)

      assert Enum.any?(error.errors, &match?(%AshArcadic.Errors.QueryFailed{}, &1)),
             "expected the failure to surface as a QueryFailed, got: #{inspect(error.errors)}"

      assert Exception.message(error) =~ "ArcadeDB error (database_not_found)"

      # The probed 500 detail embeds the database NAME — tenant-derived on :context.
      for leak <- AbsentDbClient.sentinels() ++ ["not available", "Internal error"] do
        refute Exception.message(error) =~ leak
        refute inspect(error) =~ leak
      end
    end
  end

  describe "write tier: the session BEGIN collapse against live bodies" do
    test "bad credentials on create surface the static begin-failure reason, logs stay clean" do
      {result, log} =
        with_log(fn ->
          BadCredsDoc
          |> Ash.Changeset.for_create(:create, %{name: "x"})
          |> Ash.create()
        end)

      assert {:error, error} = result

      assert Enum.any?(error.errors, &match?(%AshArcadic.Errors.CreateFailed{}, &1)),
             "expected the failure to surface as a CreateFailed, got: #{inspect(error.errors)}"

      assert Exception.message(error) =~ "could not begin ArcadeDB transaction"

      # The begin error carries quarantined message/detail fields — neither the error
      # surface nor the unwind logs may echo them.
      for leak <- BadCredsClient.sentinels() ++ ["Security error", "not valid"] do
        refute Exception.message(error) =~ leak
        refute inspect(error) =~ leak
        refute log =~ leak
      end
    end

    test "a missing database on create surfaces the static begin-failure reason — no db name" do
      assert {:error, error} =
               AbsentDbDoc
               |> Ash.Changeset.for_create(:create, %{name: "x"})
               |> Ash.create()

      assert Enum.any?(error.errors, &match?(%AshArcadic.Errors.CreateFailed{}, &1)),
             "expected the failure to surface as a CreateFailed, got: #{inspect(error.errors)}"

      assert Exception.message(error) =~ "could not begin ArcadeDB transaction"

      for leak <- AbsentDbClient.sentinels() ++ ["not available"] do
        refute Exception.message(error) =~ leak
        refute inspect(error) =~ leak
      end
    end
  end
end
