exclude = if System.get_env("ARCADIC_TEST_URL"), do: [], else: [:integration]

if Code.ensure_loaded?(Replicant.Sink) do
  IO.puts("CDC tests enabled: Replicant.Sink is available")
else
  IO.puts(
    "Non-CDC host: excluding test/ash_arcadic/replicant/*.exs and " <>
      "test/integration/replicant_sink_test.exs; Replicant.Sink is absent"
  )
end

ExUnit.start(exclude: exclude)
