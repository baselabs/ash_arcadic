defmodule AshArcadic.DataLayer.VectorCandidateCeilingTest do
  @moduledoc """
  The `max_vector_candidates` fail-closed ceiling (R13 probe-verification — the knob had NO
  test anywhere): an `:attribute`-scoped vector search builds its candidate RID set from a
  tenant-filtered read, and a set exceeding the configured ceiling must FAIL CLOSED (never
  truncate — truncation could silently drop the true nearest neighbour), while a set within
  the ceiling proceeds to the kNN call. Also pins the CV-4 config-validation fallback: a
  non-pos-integer config value (e.g. a string "2") must fall back to the default — under
  Erlang term ordering every integer is SMALLER than every binary, so a raw
  `length(rids) > "2"` is always FALSE and an unvalidated value would silently DISABLE the
  ceiling (fail open).

  `async: false`: mutates `Application` env (`max_vector_candidates`), restored on exit
  (deleted — the key is unset in this app's config).
  """

  use ExUnit.Case, async: false

  defmodule ScriptedTransport do
    @moduledoc false
    @behaviour Arcadic.Transport

    @impl true
    def begin(_conn, _opts), do: {:ok, "ceiling-session"}

    @impl true
    def commit(_conn), do: :ok

    @impl true
    def rollback(_conn), do: :ok

    @impl true
    def execute(_conn, _mode, _request, _opts) do
      # First call: the tenant-scoped candidate read (`RETURN n`) — a scripted row set
      # (default: three vertices). Later calls: the kNN neighbors query — one ranked row.
      case Process.get({__MODULE__, :calls}, 0) do
        0 ->
          Process.put({__MODULE__, :calls}, 1)

          rows =
            Process.get({__MODULE__, :candidate_rows}) ||
              [%{"@rid" => "#12:0"}, %{"@rid" => "#12:1"}, %{"@rid" => "#12:2"}]

          {:ok, rows}

        _ ->
          {:ok, [%{"id" => "nearest", "distance" => 0.1}]}
      end
    end
  end

  defmodule ScriptedClient do
    @moduledoc false
    @behaviour AshArcadic.Client

    @impl true
    def conn do
      Arcadic.connect("http://ceiling.invalid", "ceiling_db",
        auth: {"root", "ceiling_pw"},
        transport: ScriptedTransport
      )
    end
  end

  defmodule CeilDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.DataLayer.VectorCandidateCeilingTest.ScriptedClient)
      label(:CeilDoc)
      vector_index(:embedding, dimensions: 3, similarity: :cosine)
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :org, :string, public?: true
      attribute :embedding, {:array, :float}, public?: true
    end

    multitenancy do
      strategy :attribute
      attribute :org
    end

    actions do
      default_accept [:id, :org, :embedding]
      defaults [:create]

      read :read do
        primary? true
      end
    end
  end

  @stash %{
    kind: :dense,
    index: :embedding,
    query_vector: [1.0, 0.0, 0.0],
    k: 2,
    allow_global?: false,
    opts: []
  }

  setup do
    Process.put({ScriptedTransport, :calls}, 0)
    Process.delete({ScriptedTransport, :candidate_rows})
    on_exit(fn -> Application.delete_env(:ash_arcadic, :max_vector_candidates) end)
    :ok
  end

  defp script_rows(rows), do: Process.put({ScriptedTransport, :candidate_rows}, rows)

  defp run_vector_read(tenant) do
    query = %AshArcadic.Query{
      resource: CeilDoc,
      label: "CeilDoc",
      tenant: tenant,
      vector_search: @stash
    }

    AshArcadic.DataLayer.run_query(query, CeilDoc)
  end

  test "a candidate set over the ceiling fails closed — never truncates" do
    Application.put_env(:ash_arcadic, :max_vector_candidates, 2)

    assert {:error, error} = run_vector_read("org_a")
    assert Exception.message(error) =~ "max_vector_candidates"
    # value-free: no RID or tenant in the message
    refute Exception.message(error) =~ "#12:"
    refute Exception.message(error) =~ "org_a"
  end

  test "a candidate set within the ceiling proceeds to the kNN call" do
    Application.put_env(:ash_arcadic, :max_vector_candidates, 3)

    assert {:ok, [record]} = run_vector_read("org_a")
    assert record.id == "nearest"
  end

  test "a non-pos-integer config falls back to the default (CV-4) — the ceiling never fails open" do
    # Under Erlang term ordering every integer < every binary, so a raw `length(rids) > "2"`
    # is ALWAYS false — an unvalidated config value would DISABLE the ceiling entirely. The
    # validated fallback must treat "2" as the 10_000 default: a 10_001-row set still trips.
    Application.put_env(:ash_arcadic, :max_vector_candidates, "2")

    rows = Enum.map(0..10_000//1, fn i -> %{"@rid" => "#12:#{i}"} end)
    script_rows(rows)

    assert {:error, error} = run_vector_read("org_a")
    assert Exception.message(error) =~ "max_vector_candidates"
  end
end
