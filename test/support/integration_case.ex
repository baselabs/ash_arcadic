defmodule AshArcadic.Test.IntegrationCase do
  @moduledoc """
  Base case for AshArcadic integration tests. Creates a randomized throwaway
  database (never `commercegraph`), points `IntegrationClient` at it via app env,
  and drops it on exit. `async: false` — ArcadeDB serializes one session per
  connection, and the app-env database name is process-global.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      use ExUnit.Case, async: false
    end
  end

  setup_all do
    url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
    pass = System.get_env("ARCADIC_TEST_PASSWORD", "arcadedb_dev_password")
    database = "ashx_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    admin = Arcadic.connect(url, database, auth: {"root", pass})

    :ok = Arcadic.Server.create_database!(admin, database)
    Application.put_env(:ash_arcadic, :integration_database, database)
    on_exit(fn -> Arcadic.Server.drop_database(admin, database) end)

    {:ok, database: database, admin: admin}
  end
end
