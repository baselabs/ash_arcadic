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
  alias AshArcadic.Errors.TransactionConflict

  require Logger

  @marker_key :ash_arcadic_tx_marker
  @session_key :ash_arcadic_tx_session
  @rollback_tag :ash_arcadic_rollback

  @type conn_error ::
          :cross_database_transaction
          | :cross_route_transaction
          | :transaction_begin_failed
          | :transaction_required
          | :unsupported_lock_transport

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

  @doc "Identity of the connection target, including transport and credentials."
  @spec same_route?(Conn.t(), Conn.t()) :: boolean()
  def same_route?(%Conn{} = a, %Conn{} = b) do
    a.base_url == b.base_url and a.database == b.database and
      a.transport == b.transport and a.transport_options == b.transport_options and
      a.auth == b.auth
  end

  @doc """
  Resolve a database-targeted connection. The first write or lock read opens
  a session. Calls targeting its route reuse it. Other reads use their own
  connection, and writes across routes fail closed.
  """
  @spec resolve_conn(Conn.t(), :read | :write | :lock) :: {:ok, Conn.t()} | {:error, conn_error()}
  def resolve_conn(%Conn{} = conn, :lock) do
    cond do
      not in_transaction?() -> {:error, :transaction_required}
      conn.transport != Arcadic.Transport.HTTP -> {:error, :unsupported_lock_transport}
      true -> resolve_conn(conn, :write)
    end
  end

  def resolve_conn(%Conn{} = conn, mode) when mode in [:read, :write] do
    case session() do
      nil ->
        if in_transaction?() and mode == :write do
          open_session(conn)
        else
          {:ok, conn}
        end

      %Conn{} = session_conn ->
        cond do
          same_route?(conn, session_conn) -> {:ok, session_conn}
          mode == :read -> {:ok, conn}
          conn.database != session_conn.database -> {:error, :cross_database_transaction}
          true -> {:error, :cross_route_transaction}
        end
    end
  end

  # Resolve-then-begin: `conn` is already targeted at its database on a NON-session base
  # conn, so `Arcadic.Transaction.begin/2` never clears a live session (with_database nils
  # session_id). A begin failure surfaces as a value-free atom — the arcadic transport
  # already spans the detail; we never carry a database name or transport error text out.
  # Sessions begin at repeatable read on HTTP so a later lock read can join a
  # session opened by a write, without changing its isolation mid-transaction.
  defp open_session(conn) do
    opts =
      if conn.transport == Arcadic.Transport.HTTP, do: [isolation: :repeatable_read], else: []

    case Arcadic.Transaction.begin(%{conn | hosts: []}, opts) do
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
        :ok ->
          {:ok, result}

        {:error, error} ->
          rollback_or_log()
          {:error, commit_error(error)}
      end
    rescue
      exception ->
        rollback_or_log()
        reraise exception, __STACKTRACE__
    catch
      :throw, {@rollback_tag, reason} ->
        rollback_or_log()
        {:error, reason}

      # Any other non-local exit still rolls the session back before it propagates.
      kind, value when kind in [:throw, :exit] ->
        rollback_or_log()
        :erlang.raise(kind, value, __STACKTRACE__)
    after
      clear()
    end
  end

  defp commit_error(%Arcadic.Error{reason: :concurrent_modification}),
    do: TransactionConflict.exception([])

  defp commit_error(_error), do: :transaction_commit_failed

  @doc false
  def reject_conflict({:error, %Arcadic.Error{reason: :concurrent_modification}} = result, conn) do
    if is_binary(conn.session_id) and in_transaction?() do
      rollback_throw(TransactionConflict.exception([]))
    else
      result
    end
  end

  def reject_conflict(result, _conn), do: result

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

  # Roll back a lazily-opened session during unwind, logging a VALUE-FREE warning if the
  # rollback itself fails ({:error, _}) or raises — never masking the original error
  # (spec §4 / decision #8). The failure reason/exception is deliberately NOT interpolated:
  # an %Arcadic.Error{}.message (or a transport raise) can name a tenant-derived database, so
  # only a static line is logged (AGENTS.md Rule 4). Always returns :ok.
  @spec rollback_or_log() :: :ok
  defp rollback_or_log do
    case rollback_if_open() do
      :ok ->
        :ok

      {:error, _reason} ->
        Logger.warning(
          "AshArcadic: transaction rollback failed during unwind (original error preserved)"
        )
    end
  rescue
    _exception ->
      Logger.warning(
        "AshArcadic: transaction rollback raised during unwind (original error preserved)"
      )
  end
end
