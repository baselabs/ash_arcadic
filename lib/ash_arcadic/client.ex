defmodule AshArcadic.Client do
  @moduledoc """
  A host module that supplies the `Arcadic.Conn` a resource's data layer executes
  through — the `repo` analog for `ash_postgres`/`ash_age`. The host owns
  `base_url`, `auth`, transport, and pool; AshArcadic asks only for the handle.

      defmodule MyApp.ArcadicClient do
        @behaviour AshArcadic.Client
        @impl true
        def conn, do: Arcadic.connect(url, "my_db", auth: {"root", pass})
      end

  Reference it from a resource: `arcade do client MyApp.ArcadicClient end`.
  """

  @doc "Return a base `Arcadic.Conn`. Called per operation; `Conn` is pure data (cheap)."
  @callback conn() :: Arcadic.Conn.t()
end
