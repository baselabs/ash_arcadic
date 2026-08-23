defmodule AshArcadic.DataLayer.WriteCommandRetryTest do
  @moduledoc """
  Unit tests for the MVCC autocommit write-retry loop (`write_command/3` →
  `autocommit_write/4`): convergence on the retriable error classes, bounded
  exhaustion, non-retriable passthrough, the `write_conflict_retries` knob, and
  the session-conn bypass (conflicts surface at COMMIT, never retried here).

  Fault injection rides the transport seam arcadic's behaviour documents as this
  repo's mock seam: a conn whose `transport:` is `AshArcadic.Test.FlakyCommandTransport`,
  scripted from the process dictionary. No server involved.
  """

  use ExUnit.Case, async: true

  alias AshArcadic.DataLayer
  alias AshArcadic.Test.FlakyCommandTransport

  @conflict {:error, %Arcadic.Error{reason: :concurrent_modification}}
  @server_error {:error, %Arcadic.Error{reason: :server_error}}

  setup do
    conn =
      Arcadic.connect("http://127.0.0.1:9", "ash_arcadic_test",
        auth: {"root", "pw"},
        transport: FlakyCommandTransport
      )

    %{conn: conn}
  end

  describe "retriable classes converge (retry-then-succeed)" do
    test ":concurrent_modification — the MVCC optimistic-lock conflict", %{conn: conn} do
      FlakyCommandTransport.reset([@conflict, @conflict], {:ok, [%{"n" => 1}]})

      assert {:ok, [%{"n" => 1}]} = DataLayer.write_command(conn, "CREATE (n:Stub)", %{})
      # 2 failed attempts + the succeeding third.
      assert FlakyCommandTransport.calls() == 3
    end

    test ":server_error — the cold-start type-creation stampede class", %{conn: conn} do
      FlakyCommandTransport.reset([@server_error], {:ok, []})

      assert {:ok, []} = DataLayer.write_command(conn, "CREATE (n:Stub)", %{})
      assert FlakyCommandTransport.calls() == 2
    end

    test "every attempt rides the server-side retries budget (two-level retry design)", %{
      conn: conn
    } do
      FlakyCommandTransport.reset([@conflict], {:ok, []})

      assert {:ok, []} = DataLayer.write_command(conn, "CREATE (n:Stub)", %{})

      # The client retry is the SECOND level; the first (server-side `retries:` budget)
      # must ride every autocommit attempt, de-correlated from the client one.
      assert_received {:flaky_command, 1, :write, _request, opts}
      assert opts[:retries] == 10
      assert_received {:flaky_command, 2, :write, _request, opts}
      assert opts[:retries] == 10
    end
  end

  describe "exhaustion is bounded and returns the final error" do
    test "default: exactly 5 attempts (1 initial + 4 retries), then the error", %{conn: conn} do
      FlakyCommandTransport.reset([], @conflict)

      assert @conflict = DataLayer.write_command(conn, "CREATE (n:Stub)", %{})
      assert FlakyCommandTransport.calls() == 5
    end
  end

  describe "deterministic error classes are NEVER retried" do
    # Post-send ambiguity (:timeout — a committed-but-unacked write would duplicate) and
    # permanent failures (parse/auth/db-missing/unique) must fail on the first attempt.
    @deterministic_classes [
      :timeout,
      :database_not_found,
      :parse_error,
      :unauthorized,
      :duplicate_key,
      :not_idempotent
    ]

    for reason <- @deterministic_classes do
      test "#{reason}: single attempt, error passed through unchanged", %{conn: conn} do
        reason = unquote(reason)
        error = {:error, %Arcadic.Error{reason: reason}}
        FlakyCommandTransport.reset([], error)

        assert ^error = DataLayer.write_command(conn, "CREATE (n:Stub)", %{})
        assert FlakyCommandTransport.calls() == 1
      end
    end
  end

  describe "the write_conflict_retries knob" do
    test "N bounds total attempts; 1 disables the client retry layer", %{conn: conn} do
      Application.put_env(:ash_arcadic, :write_conflict_retries, 2)
      # The key is unset in every config — delete (not put-back) is the correct restore.
      on_exit(fn -> Application.delete_env(:ash_arcadic, :write_conflict_retries) end)

      FlakyCommandTransport.reset([], @conflict)
      assert @conflict = DataLayer.write_command(conn, "CREATE (n:Stub)", %{})
      assert FlakyCommandTransport.calls() == 2

      Application.put_env(:ash_arcadic, :write_conflict_retries, 1)
      FlakyCommandTransport.reset([], @conflict)
      assert @conflict = DataLayer.write_command(conn, "CREATE (n:Stub)", %{})
      assert FlakyCommandTransport.calls() == 1
    end

    test "a retriable error still converges under a raised knob", %{conn: conn} do
      Application.put_env(:ash_arcadic, :write_conflict_retries, 4)
      on_exit(fn -> Application.delete_env(:ash_arcadic, :write_conflict_retries) end)

      FlakyCommandTransport.reset([@conflict, @conflict, @conflict], {:ok, []})
      assert {:ok, []} = DataLayer.write_command(conn, "CREATE (n:Stub)", %{})
      assert FlakyCommandTransport.calls() == 4
    end
  end

  describe "a session conn bypasses the autocommit retry" do
    test "conflicts surface at COMMIT — one call, no statement retry", %{conn: conn} do
      session_conn = %{conn | session_id: "stub-session-1"}
      FlakyCommandTransport.reset([], @conflict)

      assert @conflict = DataLayer.write_command(session_conn, "CREATE (n:Stub)", %{})
      assert FlakyCommandTransport.calls() == 1
      refute_received {:flaky_command, 2, _, _, _}
    end
  end
end
