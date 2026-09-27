defmodule AshArcadic.Test.IntegrationClient do
  @moduledoc false
  @behaviour AshArcadic.Client

  alias AshArcadic.Test.TestURL

  @impl true
  def conn do
    url = TestURL.base()
    pass = System.get_env("ARCADIC_TEST_PASSWORD", "arcadedb_dev_password")
    database = Application.fetch_env!(:ash_arcadic, :integration_database)
    Arcadic.connect(url, database, auth: {"root", pass})
  end
end
