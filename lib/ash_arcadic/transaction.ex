defmodule AshArcadic.Transaction do
  @moduledoc false
  # Owner-process-only transaction state for the AshArcadic data layer. The marker and a
  # lazily-opened `arcadic` session live in THIS process's dictionary. Ash runs a
  # transactional action synchronously in the caller's process and disables async while
  # in a transaction (`Ash.ProcessHelpers.task_with_timeout` gates on `!in_transaction?`),
  # and transfers only tracer context to spawned tasks — so no data-layer op runs in a
  # `$callers`-child of the transaction owner. No ETS, no `Process.info`, no cross-process
  # reads. Supersedes the main spec §12's `$callers`-aware framing (Plan-3 spec §3/§4).

  alias Arcadic.Conn

  @marker_key :ash_arcadic_tx_marker
  @session_key :ash_arcadic_tx_session
  @rollback_tag :ash_arcadic_rollback

  @doc "True when the current process is inside an AshArcadic transaction (marker set)."
  @spec in_transaction?() :: boolean()
  def in_transaction?, do: Process.get(@marker_key) == true

  @doc "Set the transaction marker (transaction/4 calls this before running the fun)."
  @spec begin_marker() :: :ok
  def begin_marker do
    Process.put(@marker_key, true)
    :ok
  end

  @doc "Delete the marker and any stashed session (transaction/4's `after` block)."
  @spec clear() :: :ok
  def clear do
    Process.delete(@marker_key)
    Process.delete(@session_key)
    :ok
  end

  @doc "The stashed session conn for this process, or nil."
  @spec session() :: Conn.t() | nil
  def session, do: Process.get(@session_key)

  @doc "Stash the session conn for this process (set when the first write opens it)."
  @spec put_session(Conn.t()) :: :ok
  def put_session(%Conn{} = conn) do
    Process.put(@session_key, conn)
    :ok
  end

  @doc "Abort the current transaction; transaction/4 catches this and returns {:error, reason}."
  @spec rollback_throw(term()) :: no_return()
  def rollback_throw(reason), do: throw({@rollback_tag, reason})
end
