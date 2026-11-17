# Runs one Livebook notebook top to bottom, the way Livebook evaluates it, against this
# checkout of AshArcadic:
#
#     elixir scripts/run_notebook.exs livebooks/tour.livemd
#
# * Cells are the top-level ```elixir fences, in order. A fence that Livebook marks
#   `force_markdown` is prose, not a cell. A notebook with no cells fails.
# * The first cell must be the setup cell, holding the notebook's only `Mix.install/2`.
#   Its `:ash_arcadic` dependency is rewritten to `path:` this checkout, so the notebook runs
#   the code under test rather than the last Hex release. A setup cell without exactly one
#   `:ash_arcadic` dependency fails.
# * Every other cell is evaluated with the bindings and the environment (aliases, imports,
#   requires) the cells before it left, as Livebook carries them, in one process, so a
#   `receive` sees messages sent to an earlier cell's caller.
#
# Connection values come from the environment variables each notebook already documents
# (`ARCADEDB_URL`, `ARCADEDB_PASSWORD`).
# Each notebook needs its own OS process: `Mix.install/2` runs once per VM.

defmodule AshArcadic.NotebookRunner do
  @checkout Path.expand("..", __DIR__)

  def main([path]) do
    cells = path |> File.read!() |> cells(path)

    if cells == [] do
      fail(path, "has no elixir cells")
    end

    [{setup_line, setup} | rest] = cells
    Enum.each(rest, &refuse_install(path, &1))
    install(path, setup_line, setup)

    env = Code.env_for_eval(file: Path.expand(path))
    Enum.reduce(rest, {[], env}, &evaluate(path, &1, &2))

    IO.puts("#{path}: #{length(cells)} cells ok")
  end

  def main(_args) do
    IO.puts(:stderr, "usage: elixir scripts/run_notebook.exs NOTEBOOK.livemd")
    System.halt(2)
  end

  defp evaluate(path, {line, code}, {binding, env}) do
    quoted = Code.string_to_quoted!(code, file: path, line: line)

    try do
      {_value, binding, env} = Code.eval_quoted_with_env(quoted, binding, env)
      IO.puts("#{path}:#{line} ok")
      {binding, env}
    rescue
      error -> cell_failed(path, line, :error, error, __STACKTRACE__)
    catch
      kind, reason -> cell_failed(path, line, kind, reason, __STACKTRACE__)
    end
  end

  defp cell_failed(path, line, kind, reason, stacktrace) do
    fail(path, "cell at line #{line} failed:\n" <> Exception.format(kind, reason, stacktrace))
  end

  # Top-level fenced blocks only: Livebook cells never nest, so an indented or quoted fence
  # is prose. Returns `[{first_code_line, code}]` for every ```elixir fence that is not
  # marked force_markdown.
  defp cells(source, path) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> collect(path, :prose, false, [])
    |> Enum.reverse()
  end

  defp collect([], _path, :prose, _forced, acc), do: acc

  defp collect([], path, {_kind, first, _forced, _lines}, _, _acc) do
    fail(path, "has an unclosed fence opened before line #{first}")
  end

  defp collect([{text, line} | rest], path, :prose, forced, acc) do
    cond do
      force_markdown?(text) -> collect(rest, path, :prose, true, acc)
      fence?(text) -> collect(rest, path, {fence_kind(text), line + 1, forced, []}, false, acc)
      String.trim(text) == "" -> collect(rest, path, :prose, forced, acc)
      true -> collect(rest, path, :prose, false, acc)
    end
  end

  defp collect([{text, _line} | rest], path, {kind, first, forced, lines}, _, acc) do
    cond do
      String.trim_trailing(text) != "```" ->
        collect(rest, path, {kind, first, forced, [text | lines]}, false, acc)

      kind == "elixir" and not forced ->
        cell = {first, lines |> Enum.reverse() |> Enum.join("\n")}
        collect(rest, path, :prose, false, [cell | acc])

      true ->
        collect(rest, path, :prose, false, acc)
    end
  end

  defp force_markdown?(text) do
    String.starts_with?(text, "<!-- livebook:") and
      String.contains?(text, ~s("force_markdown":true))
  end

  defp fence?(text), do: String.starts_with?(text, "```")

  defp fence_kind(text), do: text |> String.trim_leading("`") |> String.trim()

  defp install(path, line, code) do
    {quoted, counts} =
      code
      |> Code.string_to_quoted!(file: path, line: line)
      |> Macro.prewalk(%{install: 0, ash_arcadic: 0}, &rewrite_install/2)

    cond do
      counts.install != 1 -> fail(path, "the first cell must hold the notebook's Mix.install/2")
      counts.ash_arcadic != 1 -> fail(path, "the setup cell must install :ash_arcadic exactly once")
      true -> :ok
    end

    Code.eval_quoted(quoted, [], file: path, line: line)
    IO.puts("#{path}:#{line} setup ok (ash_arcadic from #{@checkout})")
  end

  defp rewrite_install({{:., _, [{:__aliases__, _, [:Mix]}, :install]}, _, _} = node, counts) do
    {call, meta, args} = node
    {args, ash_arcadic} = rewrite_args(args)
    {{call, meta, args}, %{counts | install: counts.install + 1, ash_arcadic: ash_arcadic}}
  end

  defp rewrite_install(node, counts), do: {node, counts}

  defp rewrite_args([deps | opts]) when is_list(deps) do
    {deps, ash_arcadic} = Enum.map_reduce(deps, 0, &rewrite_dep/2)
    {[deps | opts], ash_arcadic}
  end

  defp rewrite_args(args), do: {args, 0}

  defp rewrite_dep({:ash_arcadic, _requirement}, n), do: {{:ash_arcadic, [path: @checkout]}, n + 1}
  defp rewrite_dep({:{}, _, [:ash_arcadic | _]}, n), do: {{:ash_arcadic, [path: @checkout]}, n + 1}
  defp rewrite_dep(dep, n), do: {dep, n}

  defp refuse_install(path, {line, code}) do
    if code =~ ~r/\bMix\.install\b/ do
      fail(path, "calls Mix.install/2 outside the first cell (line #{line})")
    end
  end

  defp fail(path, message) do
    IO.puts(:stderr, "#{path}: #{message}")
    System.halt(1)
  end
end

AshArcadic.NotebookRunner.main(System.argv())
