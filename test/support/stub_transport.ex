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
    Process.get(:stub_rollback_result, :ok)
  end
end
