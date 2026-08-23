defmodule AshArcadic.Test.FlakyCommandTransport do
  @moduledoc false
  # Command-path fault injection for unit tests — the transport seam Arcadic.Transport's
  # moduledoc documents as ash_arcadic's mock seam. `execute/4` pops scripted outcomes
  # from the process dictionary; when the script is exhausted it returns the `:default`
  # outcome (`{:ok, []}` unless overridden). Every call increments a counter and messages
  # the test process, so tests assert exact attempt counts and the opts each attempt saw.
  #
  # Process-dict keys:
  #   {__MODULE__, :script}  — list of results returned once, in order (default [])
  #   {__MODULE__, :default} — result returned once the script is exhausted (default {:ok, []})
  #   {__MODULE__, :calls}   — observed call count (read via calls/0)

  @behaviour Arcadic.Transport

  @impl true
  def execute(conn, mode, request, opts) do
    count = Process.get({__MODULE__, :calls}, 0) + 1
    Process.put({__MODULE__, :calls}, count)
    send(self(), {:flaky_command, count, mode, request, opts})

    case Process.get({__MODULE__, :script}, []) do
      [next | rest] ->
        Process.put({__MODULE__, :script}, rest)
        next

      [] ->
        _ = conn
        Process.get({__MODULE__, :default}, {:ok, []})
    end
  end

  # Observed attempt count for the current test process.
  def calls, do: Process.get({__MODULE__, :calls}, 0)

  # Reset the script/counter; call in setup so tests cannot inherit each other's state.
  def reset(script \\ [], default \\ {:ok, []}) do
    Process.put({__MODULE__, :script}, script)
    Process.put({__MODULE__, :default}, default)
    Process.put({__MODULE__, :calls}, 0)
  end
end
