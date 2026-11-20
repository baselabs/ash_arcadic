#!/usr/bin/env bash
set -euo pipefail

# Fetch the locked dependencies first. Inspect the transport's own requirement without
# compiling it or loading cached beams: a lane must test a host its Elixir can run.
mode=$(elixir -e '
  Mix.start()
  requirement = Mix.Project.in_project(:replicant, "deps/replicant", fn _ ->
    Keyword.fetch!(Mix.Project.config(), :elixir)
  end)
  compatible? = Version.match?(System.version(), requirement)
  mode = if compatible?, do: "CDC", else: "non-CDC"
  reason = if compatible?, do: "satisfies", else: "does not satisfy"
  IO.puts(:stderr, "Host mode: #{mode}; Elixir #{System.version()} #{reason} replicant requirement #{requirement}")
  IO.puts(mode)
')

case "$mode" in
  CDC) exit 0 ;;
  non-CDC) ;;
  *) echo "::error::Unexpected host mode: $mode" >&2; exit 1 ;;
esac

# Only this disposable CI checkout changes; retain the non-vacuity and syntax guards.
elixir -e '
  source = File.read!("mix.exs")
  stripped = Regex.replace(~r/^[\t ]*\{:replicant,.*\n/m, source, "")

  if stripped == source or String.contains?(stripped, "{:replicant,") do
    raise "guard vacuous: the {:replicant, ...} dependency line was not removed; update ci_host_mode.sh"
  end

  case Code.string_to_quoted(stripped) do
    {:ok, _} -> File.write!("mix.exs", stripped)
    {:error, _} -> raise "guard broke mix.exs syntax (multi-line replicant tuple?); update ci_host_mode.sh"
  end
'
mix deps.unlock replicant
