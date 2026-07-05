defmodule AshArcadic.Test.StubTransport do
  @moduledoc false
  # A no-server `arcadic` transport for unit tests. `Arcadic.Transaction.begin/2` calls
  # `conn.transport.begin(conn, opts)` expecting `{:ok, session_id}`; commit/rollback call
  # `conn.transport.{commit,rollback}(conn)`. Each call sends a message to the caller
  # process so tests can `assert_received`. Outcomes are overridable via the process dict.

  def begin(_conn, _opts) do
    send(self(), {:stub_transport, :begin})
    Process.get(:stub_begin_result, {:ok, "stub-session-1"})
  end

  def commit(_conn) do
    send(self(), {:stub_transport, :commit})
    Process.get(:stub_commit_result, :ok)
  end

  def rollback(_conn) do
    send(self(), {:stub_transport, :rollback})

    case Process.get(:stub_rollback_result, :ok) do
      # `:raise` makes the transport rollback RAISE (not return a tuple), so unwind-path
      # tests can prove the rollback failure is caught + logged value-free and never masks
      # the original error. The sentinel below must never appear in a log line.
      :raise -> raise "stub rollback boom (SENTINEL_RBK_RAISE_db_acme)"
      other -> other
    end
  end
end
