exclude = if System.get_env("ARCADIC_TEST_URL"), do: [], else: [:integration]
ExUnit.start(exclude: exclude)
