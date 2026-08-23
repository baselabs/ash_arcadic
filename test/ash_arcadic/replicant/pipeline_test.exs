defmodule AshArcadic.Replicant.PipelineTest do
  @moduledoc false
  # No-server unit tests for `AshArcadic.Replicant.Pipeline.start_link/1` +
  # `child_spec/1` — the supervision-child contract the handoff's carried scope
  # item R8 names: the `:temporary` restart semantics (a fail-closed halt must be
  # permanent; a boot-trigger child must not auto-restart into a duplicate
  # pipeline), the fail-closed `Impl.config/1` boot (a duplicate source_table
  # fails the host's boot loud), the checkpoint-read-fault halt, and the
  # required-opt `fetch!` guards. `start_mode/1` selection is covered in
  # `sink_test.exs`; the live pipeline bootstrap is the integration tier.
  #
  # The final `Replicant.start_link/1` call is exercised THROUGH this module with
  # a structurally-present but invalid `publication` — `Replicant.Config` rejects
  # it deterministically (`{:error, :invalid_identifier}`, probe-verified) before
  # starting any process, which proves this module passes the error tuple through
  # to the host unchanged (fail-loud boot, no swallow) without a live Postgres.
  use ExUnit.Case, async: true

  alias AshArcadic.Replicant.Error
  alias AshArcadic.Replicant.Pipeline

  defmodule StubCheckpoint do
    @moduledoc false
    def for_slot(_slot), do: nil
  end

  # A sink whose domains carry TWO mirrors claiming the same source_table — the
  # duplicate-source ambiguity `Impl.config/1` must fail the boot on. Read-only
  # resources, so the write-action seam-lock verifier does not fire.
  defmodule Elixir.AshArcadic.Test.Replicant.PipeDupA do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.PipeDupDomain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant]

    arcade do
      client(AshArcadic.Test.MockClient)
    end

    replicant do
      source_table("pipe_dups")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Elixir.AshArcadic.Test.Replicant.PipeDupB do
    @moduledoc false
    use Ash.Resource,
      domain: AshArcadic.Test.Replicant.PipeDupDomain,
      validate_domain_inclusion?: false,
      data_layer: AshArcadic.DataLayer,
      extensions: [AshArcadic.Replicant]

    arcade do
      client(AshArcadic.Test.MockClient)
    end

    replicant do
      source_table("pipe_dups")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Elixir.AshArcadic.Test.Replicant.PipeDupDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshArcadic.Test.Replicant.PipeDupA
      resource AshArcadic.Test.Replicant.PipeDupB
    end
  end

  # Valid config, EMPTY domains: `Impl.config/1` builds (and caches) an empty
  # index successfully — the success side of the fail-closed boot.
  defmodule ValidSink do
    @moduledoc false
    use AshArcadic.ReplicantSink,
      checkpoint_resource: StubCheckpoint,
      slot_name: "pipe-valid",
      domains: []
  end

  # The duplicate-source boot-failure sink.
  defmodule DupSink do
    @moduledoc false
    use AshArcadic.ReplicantSink,
      checkpoint_resource: StubCheckpoint,
      slot_name: "pipe-dup",
      domains: [AshArcadic.Test.Replicant.PipeDupDomain]
  end

  # Sink-shaped stub (no macro): valid baked config, but checkpoint/0 RAISES —
  # drives start_link's own read-fault arm (start_mode/1 raises through it).
  defmodule FaultSink do
    @moduledoc false
    def __ash_arcadic_replicant_config__,
      do: %{domains: [], checkpoint: PipelineTest.StubCheckpoint, slot: "pipe-fault"}

    def checkpoint, do: raise("checkpoint read fault")
  end

  @base_opts [
    connection: [
      hostname: "standby.invalid",
      port: 5432,
      username: "u",
      password: "p",
      database: "d"
    ],
    publication: "pub"
  ]

  setup do
    on_exit(fn ->
      :persistent_term.erase({AshArcadic.Replicant.Sink.Impl, "pipe-valid"})
      :persistent_term.erase({AshArcadic.Replicant.Sink.Impl, "pipe-dup"})
    end)

    :ok
  end

  describe "child_spec/1" do
    test "is a :temporary supervisor child keyed by the sink's slot (a halt stays permanent)" do
      spec = Pipeline.child_spec(@base_opts ++ [sink: ValidSink])

      assert %{
               id: {AshArcadic.Replicant.Pipeline, "pipe-valid"},
               start: {AshArcadic.Replicant.Pipeline, :start_link, [opts]},
               type: :supervisor,
               restart: :temporary
             } = spec

      # The host's opts ride the start MFA verbatim.
      assert opts == @base_opts ++ [sink: ValidSink]
    end

    test "a missing :sink fails loud (KeyError), never a default" do
      assert_raise KeyError, fn -> Pipeline.child_spec(@base_opts) end
    end
  end

  describe "start_link/1 — required opts are enforced" do
    test "a missing :connection fails loud", do: assert_raise(KeyError, run_missing(:connection))

    test "a missing :publication fails loud",
      do: assert_raise(KeyError, run_missing(:publication))

    test "a missing :sink fails loud",
      do: assert_raise(KeyError, fn -> Pipeline.start_link(@base_opts) end)

    defp run_missing(key) do
      fn ->
        Pipeline.start_link(Keyword.delete(@base_opts, key) ++ [sink: ValidSink])
      end
    end
  end

  describe "start_link/1 — fail-closed boot" do
    test "a duplicate source_table RAISES (the mis-mapped mirror fails the host's boot)" do
      assert_raise ArgumentError, ~r/resolver index build failed/, fn ->
        Pipeline.start_link(@base_opts ++ [sink: DupSink])
      end
    end

    test "a checkpoint READ FAULT halts the start value-free (never a silent resume)" do
      assert_raise Error, fn ->
        Pipeline.start_link(@base_opts ++ [sink: FaultSink])
      end
    end
  end

  describe "start_link/1 — the Replicant.start_link/1 result passes through unchanged" do
    test "an error tuple reaches the host as {:error, reason} (no swallow, no raise)" do
      # A structurally-present but INVALID publication: Replicant.Config rejects it
      # deterministically before starting any process, after this module's own
      # config build and start-mode selection have succeeded — so the tuple proves
      # the full body ran and the error was returned, not re-raised or masked.
      assert {:error, :invalid_identifier} =
               Pipeline.start_link(
                 Keyword.put(@base_opts, :publication, "bad publication!") ++ [sink: ValidSink]
               )
    end
  end
end
