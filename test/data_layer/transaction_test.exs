defmodule AshArcadic.TransactionTest do
  use ExUnit.Case, async: true

  alias AshArcadic.Transaction

  setup do
    on_exit(fn -> Transaction.clear() end)
    :ok
  end

  describe "marker + session primitives" do
    test "in_transaction? is false until begin_marker, true after, false after clear" do
      refute Transaction.in_transaction?()
      assert :ok = Transaction.begin_marker()
      assert Transaction.in_transaction?()
      assert :ok = Transaction.clear()
      refute Transaction.in_transaction?()
    end

    test "session/0 is nil until put_session, then round-trips, then nil after clear" do
      conn = %Arcadic.Conn{base_url: "u", database: "t_a", auth: {"root", "pw"}, session_id: "s1"}
      assert Transaction.session() == nil
      assert :ok = Transaction.put_session(conn)
      assert Transaction.session() == conn
      Transaction.clear()
      assert Transaction.session() == nil
    end

    test "rollback_throw/1 throws the module-specific tagged tuple" do
      caught =
        try do
          Transaction.rollback_throw(:abort)
        catch
          :throw, value -> value
        end

      assert caught == {:ash_arcadic_rollback, :abort}
    end
  end

  describe "resolve_conn/2 — session open, reuse, and the cross-DB guard" do
    setup do
      base = fn db ->
        Arcadic.connect("http://127.0.0.1:41478", db,
          auth: {"root", "pw"},
          transport: AshArcadic.Test.StubTransport
        )
      end

      %{base: base}
    end

    test "no marker: passthrough for both modes (no begin)", %{base: base} do
      conn = base.("t_a")
      assert {:ok, ^conn} = AshArcadic.Transaction.resolve_conn(conn, :write)
      assert {:ok, ^conn} = AshArcadic.Transaction.resolve_conn(conn, :read)
      refute_received {:stub_transport, :begin}
    end

    test "marker + first write: opens the session, stashes it, returns the session conn", %{
      base: base
    } do
      AshArcadic.Transaction.begin_marker()
      assert {:ok, session} = AshArcadic.Transaction.resolve_conn(base.("t_a"), :write)
      assert session.session_id == "stub-session-1"
      assert session.database == "t_a"
      assert AshArcadic.Transaction.session() == session
      assert_received {:stub_transport, :begin}
    end

    test "marker + write on the SAME database reuses the session (no second begin)", %{base: base} do
      AshArcadic.Transaction.begin_marker()
      {:ok, session} = AshArcadic.Transaction.resolve_conn(base.("t_a"), :write)
      assert_received {:stub_transport, :begin}
      assert {:ok, ^session} = AshArcadic.Transaction.resolve_conn(base.("t_a"), :write)
      refute_received {:stub_transport, :begin}
    end

    # TRIPWIRE: a write resolving a DIFFERENT database than the open session must FAIL
    # CLOSED — an ArcadeDB session is single-database. Non-vacuous: without the guard the
    # second write would run on a fresh non-session conn (split-brain, non-atomic).
    test "TRIPWIRE: marker + write on a DIFFERENT database fails closed", %{base: base} do
      AshArcadic.Transaction.begin_marker()
      {:ok, _session} = AshArcadic.Transaction.resolve_conn(base.("t_a"), :write)

      assert {:error, :cross_database_transaction} =
               AshArcadic.Transaction.resolve_conn(base.("t_b"), :write)
    end

    test "marker + read on the SAME database reuses the session (read-own-writes)", %{base: base} do
      AshArcadic.Transaction.begin_marker()
      {:ok, session} = AshArcadic.Transaction.resolve_conn(base.("t_a"), :write)
      assert {:ok, ^session} = AshArcadic.Transaction.resolve_conn(base.("t_a"), :read)
    end

    test "marker + read on a DIFFERENT database runs on its own conn (not fail-closed)", %{
      base: base
    } do
      AshArcadic.Transaction.begin_marker()
      {:ok, _session} = AshArcadic.Transaction.resolve_conn(base.("t_a"), :write)
      other = base.("t_b")
      assert {:ok, ^other} = AshArcadic.Transaction.resolve_conn(other, :read)
    end

    test "marker + read BEFORE any write runs on the base conn (no session opened)", %{base: base} do
      AshArcadic.Transaction.begin_marker()
      conn = base.("t_a")
      assert {:ok, ^conn} = AshArcadic.Transaction.resolve_conn(conn, :read)
      refute_received {:stub_transport, :begin}
      assert AshArcadic.Transaction.session() == nil
    end

    test "begin failure maps to a value-free :transaction_begin_failed", %{base: base} do
      on_exit(fn -> Process.delete(:stub_begin_result) end)
      Process.put(:stub_begin_result, {:error, %Arcadic.Error{reason: :server_error}})
      AshArcadic.Transaction.begin_marker()

      assert {:error, :transaction_begin_failed} =
               AshArcadic.Transaction.resolve_conn(base.("t_a"), :write)
    end
  end

  describe "run/1 — commit / rollback / reraise / cleanup" do
    setup do
      base =
        Arcadic.connect("http://127.0.0.1:41478", "t_a",
          auth: {"root", "pw"},
          transport: AshArcadic.Test.StubTransport
        )

      %{base: base}
    end

    test "normal return with an opened session commits and returns {:ok, result}", %{base: base} do
      result =
        AshArcadic.Transaction.run(fn ->
          {:ok, _} = AshArcadic.Transaction.resolve_conn(base, :write)
          :done
        end)

      assert result == {:ok, :done}
      assert_received {:stub_transport, :begin}
      assert_received {:stub_transport, :commit}
      refute_received {:stub_transport, :rollback}
      refute AshArcadic.Transaction.in_transaction?()
    end

    test "rollback_throw rolls back the session and returns {:error, reason}", %{base: base} do
      result =
        AshArcadic.Transaction.run(fn ->
          {:ok, _} = AshArcadic.Transaction.resolve_conn(base, :write)
          AshArcadic.Transaction.rollback_throw(:abort)
        end)

      assert result == {:error, :abort}
      assert_received {:stub_transport, :rollback}
      refute_received {:stub_transport, :commit}
      refute AshArcadic.Transaction.in_transaction?()
    end

    test "a raising fun rolls back and reraises; marker still cleared", %{base: base} do
      assert_raise RuntimeError, "boom", fn ->
        AshArcadic.Transaction.run(fn ->
          {:ok, _} = AshArcadic.Transaction.resolve_conn(base, :write)
          raise "boom"
        end)
      end

      assert_received {:stub_transport, :rollback}
      refute_received {:stub_transport, :commit}
      refute AshArcadic.Transaction.in_transaction?()
    end

    test "a failing commit maps to {:error, :transaction_commit_failed} without rolling back", %{
      base: base
    } do
      on_exit(fn -> Process.delete(:stub_commit_result) end)
      Process.put(:stub_commit_result, {:error, %Arcadic.Error{reason: :server_error}})

      result =
        AshArcadic.Transaction.run(fn ->
          {:ok, _} = AshArcadic.Transaction.resolve_conn(base, :write)
          :done
        end)

      assert result == {:error, :transaction_commit_failed}
      assert_received {:stub_transport, :commit}
      refute_received {:stub_transport, :rollback}
      refute AshArcadic.Transaction.in_transaction?()
    end

    test "an unexpected exit rolls back the session and propagates; marker still cleared", %{
      base: base
    } do
      reason =
        catch_exit(
          AshArcadic.Transaction.run(fn ->
            {:ok, _} = AshArcadic.Transaction.resolve_conn(base, :write)
            exit(:boom)
          end)
        )

      assert reason == :boom
      assert_received {:stub_transport, :rollback}
      refute_received {:stub_transport, :commit}
      refute AshArcadic.Transaction.in_transaction?()
    end

    test "a fun that opens no session commits nothing and returns {:ok, result}" do
      assert {:ok, 42} = AshArcadic.Transaction.run(fn -> 42 end)
      refute_received {:stub_transport, :begin}
      refute_received {:stub_transport, :commit}
    end
  end
end
