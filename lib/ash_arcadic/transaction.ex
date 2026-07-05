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

  @doc """
  Resolve the connection an op should use, given a base conn already targeted at its
  database. Outside a transaction: the base conn, unchanged. Inside: the first WRITE opens
  the session; a write/read on the same database reuses it; a cross-database WRITE fails
  closed (single-database sessions); a cross-database or pre-write READ runs on its own
  conn (a read is not an atomicity hazard).
  """
  @spec resolve_conn(Conn.t(), :read | :write) ::
          {:ok, Conn.t()} | {:error, :cross_database_transaction | :transaction_begin_failed}
  def resolve_conn(%Conn{} = conn, mode) when mode in [:read, :write] do
    case session() do
      nil ->
        if in_transaction?() and mode == :write do
          open_session(conn)
        else
          {:ok, conn}
        end

      %Conn{database: open_db} = session_conn ->
        cond do
          open_db == conn.database -> {:ok, session_conn}
          mode == :read -> {:ok, conn}
          true -> {:error, :cross_database_transaction}
        end
    end
  end

  # Resolve-then-begin: `conn` is already targeted at its database on a NON-session base
  # conn, so `Arcadic.Transaction.begin/2` never clears a live session (with_database nils
  # session_id). A begin failure surfaces as a value-free atom — the arcadic transport
  # already spans the detail; we never carry a database name or transport error text out.
  defp open_session(conn) do
    case Arcadic.Transaction.begin(conn) do
      {:ok, %Conn{} = session_conn} ->
        put_session(session_conn)
        {:ok, session_conn}

      {:error, _error} ->
        {:error, :transaction_begin_failed}
    end
  end

  @doc """
  Run `fun` as the transaction body: set the marker, commit a lazily-opened session on a
  normal return, catch the rollback throw, roll back and reraise on any other exception or
  non-local exit, and clear the marker + session on EVERY exit path. Returns
  `{:ok, term} | {:error, term}`.
  """
  @spec run((-> term())) :: {:ok, term()} | {:error, term()}
  def run(fun) when is_function(fun, 0) do
    begin_marker()

    try do
      result = fun.()

      case commit_if_open() do
        :ok -> {:ok, result}
        {:error, _error} -> {:error, :transaction_commit_failed}
      end
    rescue
      exception ->
        _ = rollback_if_open()
        reraise exception, __STACKTRACE__
    catch
      :throw, {@rollback_tag, reason} ->
        _ = rollback_if_open()
        {:error, reason}

      # Any other non-local exit still rolls the session back before it propagates.
      kind, value when kind in [:throw, :exit] ->
        _ = rollback_if_open()
        :erlang.raise(kind, value, __STACKTRACE__)
    after
      clear()
    end
  end

  @doc "Commit the stashed session if one was opened; :ok when there is none."
  @spec commit_if_open() :: :ok | {:error, term()}
  def commit_if_open do
    case session() do
      nil -> :ok
      %Conn{} = conn -> Arcadic.Transaction.commit(conn)
    end
  end

  @doc "Roll back the stashed session if one was opened; :ok when there is none."
  @spec rollback_if_open() :: :ok | {:error, term()}
  def rollback_if_open do
    case session() do
      nil -> :ok
      %Conn{} = conn -> Arcadic.Transaction.rollback(conn)
    end
  end
end
