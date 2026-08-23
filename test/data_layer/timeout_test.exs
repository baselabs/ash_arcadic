defmodule AshArcadic.DataLayer.TimeoutTest do
  @moduledoc """
  The timeout surface (carried item R10): the three-layer receive-timeout model —
  client-conn floor, per-resource `arcade do timeout end` default, and Ash-resolved
  per-call timeouts (read action DSL `timeout` / `changeset.timeout`) — applied
  through per-op conn derivation so EVERY wire path (reads, writes, aggregates,
  vector, traversal, session ops) inherits it. The observation point is the conn
  the transport receives (its `timeout` is exactly what arcadic's `post/4` resolves
  into Req's `receive_timeout`).

  `async: false`: an action carrying a timeout runs under Ash's task wrapper (the
  data layer declares `:async_engine`), so captures must cross processes — a named
  Agent started via `start_supervised!`.
  """

  use ExUnit.Case, async: false

  alias AshArcadic.DataLayer.TimeoutTest.{CapturingTransport, Conn3sClient}

  # Records every wire call's {mode, conn.timeout} (and begin's) into an Agent,
  # returning an empty row set per call — sufficient to drive reads/aggregates
  # end-to-end while asserting only on the captured conn.
  defmodule CapturingTransport do
    @moduledoc false
    @behaviour Arcadic.Transport

    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

    def captures,
      do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

    @impl true
    def begin(conn, _opts) do
      Agent.update(__MODULE__, &[{:begin, conn.timeout} | &1])
      {:ok, "capture-session"}
    end

    @impl true
    def commit(_conn), do: :ok

    @impl true
    def rollback(_conn), do: :ok

    @impl true
    def execute(conn, mode, _request, _opts) do
      Agent.update(__MODULE__, &[{mode, conn.timeout} | &1])
      {:ok, []}
    end
  end

  # The client owns the conn — its 3_000 receive timeout is the FLOOR the design
  # must never disturb when no narrower timeout applies.
  defmodule Conn3sClient do
    @moduledoc false
    @behaviour AshArcadic.Client

    @impl true
    def conn do
      Arcadic.connect("http://timeout.invalid", "timeout_db",
        auth: {"root", "timeout_pw"},
        transport: CapturingTransport,
        timeout: 3_000
      )
    end
  end

  defmodule PlainDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.DataLayer.TimeoutTest.Conn3sClient)
      label(:TimeoutPlain)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:name]
      defaults [:read, :create]
    end
  end

  # The per-resource default (A″): 7_000 beats the client conn's 3_000 on every
  # wire call of this resource — reads, writes, aggregates, vector, session ops.
  defmodule ResDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.DataLayer.TimeoutTest.Conn3sClient)
      label(:TimeoutRes)
      timeout 7_000
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:name]
      defaults [:read, :create]
    end
  end

  # The Ash-native per-read-action timeout (B): 5_000 beats the resource default
  # on this action's wire calls. The action-DSL timeout is the only call-site-ish
  # knob Ash actually seeds into the data-layer context (query.ex:4508).
  defmodule SlowDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.DataLayer.TimeoutTest.Conn3sClient)
      label(:TimeoutSlow)
      timeout 7_000
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:name]
      defaults [:create]

      read :slow do
        primary? true
        timeout 5_000
      end
    end
  end

  setup do
    start_supervised!(%{
      id: CapturingTransport,
      start: {Agent, :start_link, [fn -> [] end, [name: CapturingTransport]]}
    })

    CapturingTransport.reset()
    :ok
  end

  describe "the Ash :timeout capability" do
    test "Ash.Query.timeout/2 is accepted (no TimeoutNotSupported error)" do
      query = Ash.Query.timeout(Ash.Query.new(PlainDoc), 5_000)
      assert query.errors == []
    end
  end

  describe "the client conn floor" do
    test "a read with no other timeout sees the client conn's timeout at the wire" do
      assert {:ok, []} = Ash.read(PlainDoc)
      assert [{:read, 3_000}] = CapturingTransport.captures()
    end

    test "a write conn with no other timeout keeps the client conn's timeout (write_conn)" do
      changeset = Ash.Changeset.for_create(PlainDoc, :create, %{"name" => "x"})

      assert {:ok, %Arcadic.Conn{timeout: 3_000}} =
               AshArcadic.DataLayer.write_conn(PlainDoc, changeset)
    end
  end

  describe "the per-resource default (arcade do timeout end)" do
    test "a read sees the resource timeout at the wire, beating the conn floor" do
      assert {:ok, []} = Ash.read(ResDoc)
      assert [{:read, 7_000}] = CapturingTransport.captures()
    end

    test "a write conn carries the resource timeout (write_conn)" do
      changeset = Ash.Changeset.for_create(ResDoc, :create, %{"name" => "x"})

      assert {:ok, %Arcadic.Conn{timeout: 7_000}} =
               AshArcadic.DataLayer.write_conn(ResDoc, changeset)
    end

    test "the base resource conn (traverse/vector resolution) carries the resource timeout" do
      assert %Arcadic.Conn{timeout: 7_000} = AshArcadic.DataLayer.resource_conn(ResDoc)
      assert %Arcadic.Conn{timeout: 3_000} = AshArcadic.DataLayer.resource_conn(PlainDoc)
    end
  end

  describe "Ash-resolved per-call timeouts" do
    test "a read action's DSL timeout reaches the wire, beating the resource default" do
      assert {:ok, []} = Ash.read(SlowDoc)
      assert [{:read, 5_000}] = CapturingTransport.captures()
    end

    test "set_context stashes the action timeout (ash_postgres's repo_timeout sources)" do
      action = %{timeout: 5_000}

      assert {:ok, %AshArcadic.Query{timeout: 5_000}} =
               AshArcadic.DataLayer.set_context(
                 SlowDoc,
                 %AshArcadic.Query{resource: SlowDoc},
                 %{action: action, data_layer: %{}}
               )

      # the context convention beats the action field, as in ash_postgres's repo_timeout/1
      assert {:ok, %AshArcadic.Query{timeout: 9_000}} =
               AshArcadic.DataLayer.set_context(
                 SlowDoc,
                 %AshArcadic.Query{resource: SlowDoc},
                 %{action: action, data_layer: %{timeout: 9_000}}
               )

      # a nil action must not crash (the guard ash_postgres carries)
      assert {:ok, %AshArcadic.Query{timeout: nil}} =
               AshArcadic.DataLayer.set_context(
                 SlowDoc,
                 %AshArcadic.Query{resource: SlowDoc},
                 %{data_layer: %{}}
               )
    end

    test "read_conn applies the stashed action timeout over the resource default" do
      {:ok, query} =
        AshArcadic.DataLayer.set_context(
          SlowDoc,
          %AshArcadic.Query{resource: SlowDoc},
          %{action: %{timeout: 5_000}, data_layer: %{}}
        )

      assert {:ok, %Arcadic.Conn{timeout: 5_000}} = AshArcadic.DataLayer.read_conn(query, SlowDoc)

      # no stash → the resource default stands
      assert {:ok, %Arcadic.Conn{timeout: 7_000}} =
               AshArcadic.DataLayer.read_conn(%AshArcadic.Query{resource: SlowDoc}, SlowDoc)
    end

    test "changeset.timeout reaches the write conn, beating the resource default" do
      changeset = Ash.Changeset.for_create(ResDoc, :create, %{"name" => "x"}, timeout: 9_000)

      assert {:ok, %Arcadic.Conn{timeout: 9_000}} =
               AshArcadic.DataLayer.write_conn(ResDoc, changeset)
    end

    test "an explicit changeset :infinity means no receive bound for that call" do
      changeset = Ash.Changeset.for_create(ResDoc, :create, %{"name" => "x"}, timeout: :infinity)

      assert {:ok, %Arcadic.Conn{timeout: :infinity}} =
               AshArcadic.DataLayer.write_conn(ResDoc, changeset)
    end

    test "an aggregate read on a timeout action sees the action timeout at the wire" do
      assert {:ok, 0} = Ash.count(SlowDoc)
      assert [{:read, 5_000}] = CapturingTransport.captures()
    end
  end
end
