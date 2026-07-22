defmodule AshArcadic.Replicant.Telemetry do
  @moduledoc false
  # Value-free telemetry for AshArcadic.Replicant's CDC apply — mirrors
  # `AshArcadic.Telemetry`'s allowlist + `validate!/1` pattern (AGENTS.md Rule 4 /
  # project_redaction_fail_path_exception_leak): the single enforcement point that no
  # row value reaches metadata. A SEPARATE CDC surface with its OWN allowlist — the
  # data-layer `AshArcadic.Telemetry` allowlist has no `slot`/`commit_lsn` and is not
  # reused here.
  #
  # Two flat events, emitted directly via `:telemetry.execute/3` (not
  # `AshArcadic.Telemetry.span/3`'s :start/:stop pair — there is exactly one
  # apply-or-skip decision per transaction, not a wrapped function call):
  #
  #   * `[:ash_arcadic, :replicant, :transaction, :apply]` — a real apply.
  #     Measurements: `change_count`, `duration`. Metadata: `slot`, `commit_lsn`.
  #   * `[:ash_arcadic, :replicant, :transaction, :skip]` — a replay-gate hit.
  #     Measurements: `duration`. Metadata: `slot`, `commit_lsn`.
  #
  # Metadata is `slot` + `commit_lsn` ONLY — never a `%Change{}`, a record, a column
  # value, or a tenant. `change_count` is on the allowlist (it travels as a
  # measurement today, never as metadata) so a plain integer count is never itself
  # treated as an off-allowlist leak if a future caller routes it through metadata.

  @allowed_meta_keys ~w(slot commit_lsn change_count)a

  @spec allowed_meta_keys() :: [atom()]
  def allowed_meta_keys, do: @allowed_meta_keys

  @doc """
  Emit the `:apply` event for a real apply: `change_count` changes applied and the
  checkpoint advanced to `commit_lsn`.
  """
  @spec apply_event(String.t(), integer(), non_neg_integer(), integer()) :: :ok
  def apply_event(slot, commit_lsn, change_count, duration) do
    :telemetry.execute(
      [:ash_arcadic, :replicant, :transaction, :apply],
      %{change_count: change_count, duration: duration},
      validate!(%{slot: slot, commit_lsn: commit_lsn})
    )
  end

  @doc """
  Emit the `:skip` event for a replay-gate hit: `commit_lsn` was already covered by
  the stored watermark, so no change was applied.
  """
  @spec skip_event(String.t(), integer(), integer()) :: :ok
  def skip_event(slot, commit_lsn, duration) do
    :telemetry.execute(
      [:ash_arcadic, :replicant, :transaction, :skip],
      %{duration: duration},
      validate!(%{slot: slot, commit_lsn: commit_lsn})
    )
  end

  @doc false
  def validate!(meta) when is_map(meta) do
    case Map.keys(meta) -- @allowed_meta_keys do
      [] ->
        meta

      bad ->
        raise ArgumentError,
              "replicant telemetry metadata keys #{inspect(bad)} are not in the value-free " <>
                "allowlist #{inspect(@allowed_meta_keys)} (no row-level or tenant-derived value)"
    end
  end
end
