defmodule AshArcadic.Client do
  @moduledoc """
  A host module that supplies the `Arcadic.Conn` a resource's data layer executes
  through — the `repo` analog for `ash_postgres`/`ash_age`. The host owns
  `base_url`, `auth`, transport, and pool; AshArcadic asks only for the handle.

      defmodule MyApp.ArcadicClient do
        @behaviour AshArcadic.Client
        @impl true
        def conn, do: Arcadic.connect(url, "my_db", auth: {"root", pass})

        @impl true
        def transport, do: Arcadic.Transport.HTTP
      end

  Implement `conn/1` for context-dependent routing. It receives the operation's
  tenant and Ash context with the private context and top-level actor removed.
  A context-independent client can implement `conn/0`; when both exist, `conn/1`
  is used, including for operations with no tenant or context.

  Declare `transport/0` when the client always uses one transport. Ash can
  advertise `:for_update` when that declaration names the HTTP transport.
  Connection routing still checks the actual transport when a lock runs.

  Reference it from a resource: `arcade do client MyApp.ArcadicClient end`.
  """

  @type routing_context :: %{tenant: term(), context: map()}

  @doc "Return a base `Arcadic.Conn`. Called per operation; `Conn` is pure data (cheap)."
  @callback conn() :: Arcadic.Conn.t()
  @doc "Return the base connection for an operation's tenant and action context."
  @callback conn(routing_context()) :: Arcadic.Conn.t()

  @doc "Declare the transport common to all routes, when it is known."
  @callback transport() :: module()

  @optional_callbacks conn: 0, conn: 1, transport: 0
end
