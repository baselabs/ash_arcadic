defmodule AshArcadic.Replicant.Apply do
  @moduledoc """
  Applies one decoded Postgres transaction's changes to the ArcadeDB mirror
  ATOMICALLY with the LSN watermark — the effect-once core of the
  `AshArcadic.Replicant` sink.

  ## The atomicity mechanism (Ch1)

  `apply_transaction/2` wraps the WHOLE apply in `Ash.transaction(resources, fn -> ... end)`
  — never a raw `Arcadic.transaction/3`. The data-layer `transaction/4` callback that
  `Ash.transaction/2` routes through is what sets the process marker
  (`:ash_arcadic_tx_marker`); `AshArcadic.Transaction.resolve_conn/2` opens ONE ArcadeDB
  session on the first write and every subsequent write/read reuses it, so the mirrored
  data writes AND the checkpoint upsert commit together in a single session. The
  `resources` list MUST be non-empty (it includes the checkpoint resource): a bare
  `Ash.transaction([], fn)` returns `{:ok, fun.()}` WITHOUT engaging the data layer — no
  marker, no session — so each inner `Ash.create!`/`Ash.bulk_destroy!` would auto-commit
  on its own base connection and a mid-transaction failure would leak partial writes,
  shattering effect-once. (`resources/1` is non-empty by construction; the marker being set
  inside the fn is proven by execution in the test suite. Crash-atomicity itself is proven
  live in the sink's integration slice.)

  ## The replay gate (F1 / Ch5)

  `replay_skip?/2` is `is_integer(stored) and lsn <= stored`. The `is_integer/1` guard is
  load-bearing: a `nil` (never-applied) checkpoint MUST apply, not skip — and in Erlang
  term order a number sorts before every atom, so a guardless `lsn <= nil` is ALWAYS true
  and would silently skip the never-applied transaction.

  ## Per-change invariant map

    * `:insert` / `:update` — MERGE upsert by primary key (`Ash.create!(..., upsert?: true)`).
      On an `:update` whose primary key CHANGED, the old-PK vertex is destroyed FIRST, then
      the new row upserted (no ghost row).
    * `:delete` — atomic bulk destroy by primary key. A `nil` primary-key value fails closed
      (never `id == nil`, which matches 0 rows and silently "succeeds"); a genuine 0-row
      match (already-absent) is idempotent `:ok`.
    * `:truncate` — per `on_truncate/1`: `:halt` (default) fails closed; `:mirror` runs a
      TENANT-BLIND raw `MATCH (n:Label) DETACH DELETE n` on the whole label, on the session
      connection so it is atomic with the surrounding changes and the checkpoint upsert.

  A change whose `{schema, table}` is not a mirror target is ignored (`:ok`).

  ## Value-free error boundary

  `apply_transaction/2` ALWAYS returns `{:ok, lsn} | {:error, <value-free>}` — it never
  raises and never lets a value-bearing term escape, whether the underlying failure arrived
  as a returned rollback `{:error, reason}` (an Ash data-layer write failing INSIDE the
  transaction rolls back via `AshArcadic.Transaction.rollback_throw/1`, which
  `AshArcadic.Transaction.run/1` catches and RETURNS as `{:error, reason}` — bypassing the
  per-change rescue), a raised exception, or a caught throw/exit. `boundary_error/1` lets
  only PROVABLY value-free terms cross: an `AshArcadic.Replicant.Error` (atoms only), or a
  bare structural `AshArcadic.Errors.*` data-layer error (value-free by AGENTS.md Rule 4 —
  extracted from its value-BEARING `Ash.Error` container, which carries the changeset/query,
  when wrapped). ANY other or unrecognized term maps to a static `:sink_failed` (fail closed
  — an unrecognized error is never trusted to be value-free).

  The per-change `scrub/3` is the inner layer: it converts a RAISE within one change (a
  cast/helper/guard) to a value-free `AshArcadic.Replicant.Error` carrying the correct op,
  so an op-specific reason (`:tenant_required`, `:truncate_halt`, …) survives to the
  boundary; the underlying exception's contents are never inspected.
  """

  alias AshArcadic.DataLayer.Info, as: DataLayerInfo
  alias AshArcadic.Replicant.Error
  alias AshArcadic.Replicant.Info
  alias AshArcadic.Replicant.Resolver
  alias AshArcadic.Replicant.Telemetry

  @type config :: %{
          :resolver_index => %{Resolver.source_key() => module()},
          :checkpoint => module(),
          :slot => String.t(),
          :authorize? => boolean(),
          optional(any()) => any()
        }

  @doc """
  Apply one decoded transaction's `changes` atomically with the watermark advance.

  Routes through `Ash.transaction/2` (Ch1) so the mirrored writes and the checkpoint
  upsert commit in ONE ArcadeDB session. Skips a replayed transaction (F1 gate) and
  otherwise applies every change in delivery order, then advances the checkpoint to
  `commit_lsn`. Returns `{:ok, applied_lsn}` (the Sink's `{:ok, lsn}` contract) or
  `{:error, reason}` from a rolled-back transaction.
  """
  @spec apply_transaction(config(), Replicant.Transaction.t()) ::
          {:ok, integer() | nil} | {:error, term()}
  def apply_transaction(config, %Replicant.Transaction{commit_lsn: lsn, changes: changes}) do
    # `Ash.transaction/2` returns `{:ok, result} | {:error, reason}` — `result` is the fun's
    # value (the applied/held lsn), which IS the Sink's `{:ok, lsn}` contract. The non-empty
    # resources list (Ch1) is what engages the single data-layer session. SELF-ENFORCE the
    # value-free boundary: a data-layer write failure is delivered as a rollback THROW that
    # `run/1` RETURNS as `{:error, raw}` (bypassing the per-change rescue), so route every
    # error — returned, raised, or thrown/exited — through `boundary_error/1`. The
    # empty-index guard fires BEFORE the transaction opens, so a wholesale-empty (mis-mapped)
    # sink fails closed WITHOUT advancing the checkpoint (invisible-loss guard).
    with :ok <- reject_empty_index(config),
         {:ok, applied} <- Ash.transaction(resources(config), fn -> run(config, lsn, changes) end) do
      {:ok, applied}
    else
      {:error, reason} -> {:error, boundary_error(reason)}
    end
  rescue
    exception -> {:error, boundary_error(exception)}
  catch
    kind, value when kind in [:throw, :exit] -> {:error, boundary_error(value)}
  end

  # The transaction body: read the committed watermark, apply-or-skip (F1 gate), advance.
  # Runs inside the single session opened by the first write. Telemetry (additive,
  # value-free — Telemetry.validate!/1 is the enforcement point) is emitted AFTER the
  # decision: on the apply branch, only once every change has applied and the
  # checkpoint has advanced without raising, so a rolled-back apply never emits a
  # false :apply event (a raise here propagates out to apply_transaction/2's boundary
  # and this function never reaches its telemetry call).
  defp run(config, lsn, changes) do
    start_time = System.monotonic_time()
    stored = config.checkpoint.for_slot(config.slot)

    if replay_skip?(stored, lsn) do
      Telemetry.skip_event(config.slot, lsn, System.monotonic_time() - start_time)
      stored
    else
      Enum.each(changes, &apply_change(config, &1))
      config.checkpoint.upsert_lsn(config.slot, lsn)

      Telemetry.apply_event(
        config.slot,
        lsn,
        length(changes),
        System.monotonic_time() - start_time
      )

      lsn
    end
  end

  @doc false
  # The resource set handed to `Ash.transaction/2`: the deduped mirror resources plus the
  # checkpoint. Non-empty BY CONSTRUCTION (the checkpoint is always present) — this is what
  # engages the data-layer transaction (marker + single session). Never route the apply
  # through an empty list, or the writes escape the session (Ch1).
  @spec resources(config()) :: [module(), ...]
  def resources(config) do
    (config.resolver_index |> Map.values() |> Enum.uniq()) ++ [config.checkpoint]
  end

  @doc false
  # Fail closed on a WHOLESALE-empty resolver index (`map_size == 0`) — a mirror sink with
  # NO mapped resources (empty/wrong domains). Every change would resolve to `nil` (unmapped
  # → `:ok` skip) and be silently dropped WHILE the checkpoint advances = PERMANENT, INVISIBLE
  # loss. Returns a value-free `{:error, %Error{:empty_index}}` so callers halt BEFORE
  # opening the transaction (checkpoint not advanced). CRITICAL: this fires ONLY on a
  # whole-index empty; a NON-empty index with a specific unmapped table stays a legitimate
  # partial-publication `:ok` skip (handled per-change by `apply_change/2` / per-batch by the
  # snapshot lookup). Shared by `apply_transaction/2` and the sink's snapshot callbacks so
  # the fail-closed check is identical everywhere.
  @spec reject_empty_index(config()) :: :ok | {:error, Error.t()}
  def reject_empty_index(config) do
    if map_size(config.resolver_index) == 0,
      do: {:error, Error.exception(reason: :empty_index)},
      else: :ok
  end

  @doc false
  # F1/Ch5 replay gate: skip only when a REAL (integer) watermark already covers `lsn`.
  # The `is_integer/1` guard is load-bearing — a `nil` (never-applied) checkpoint MUST
  # apply. In Erlang term order a number sorts BEFORE any atom, so `lsn <= nil` is always
  # true; a guardless `lsn <= stored` would SKIP the never-applied transaction.
  @spec replay_skip?(integer() | nil, integer()) :: boolean()
  def replay_skip?(stored, lsn), do: is_integer(stored) and lsn <= stored

  @doc """
  Apply a single change under `config`. A change whose `{schema, table}` is not a mirror
  target is ignored (`:ok`). Called per change, in delivery order, inside
  `apply_transaction/2`'s session. Raises a VALUE-FREE `AshArcadic.Replicant.Error` on any
  failure so the surrounding transaction rolls back (the fail-closed effect-once contract).
  """
  @spec apply_change(config(), Replicant.Change.t()) :: :ok
  def apply_change(config, %Replicant.Change{} = change) do
    case Resolver.lookup(config.resolver_index, change.schema, change.table) do
      nil -> :ok
      resource -> apply_to(config, resource, change)
    end
  end

  defp apply_to(config, resource, %Replicant.Change{op: op} = change)
       when op in [:insert, :update] do
    if op == :update and pk_changed?(resource, change) do
      destroy_by_pk(config, resource, change.old_record)
    end

    upsert(config, resource, change.record)
  end

  defp apply_to(config, resource, %Replicant.Change{op: :delete} = change) do
    destroy_by_pk(config, resource, change.old_record)
  end

  defp apply_to(_config, resource, %Replicant.Change{op: :truncate}) do
    truncate(resource)
  end

  # Fail closed on any op the invariant map does not cover (e.g. a `:snapshot` change, which
  # flows through the sink's separate batch path, not this live-stream apply). A value-free
  # raise — never a FunctionClauseError, which would interpolate the change struct.
  defp apply_to(_config, resource, %Replicant.Change{op: op}) do
    raise Error.exception(reason: :unsupported_op, resource: resource, op: op)
  end

  defp upsert(config, resource, record) do
    reject_empty_identity!(resource, record)
    {inputs, upsert_fields} = Resolver.attrs_for_upsert(resource, record)
    tenant = Resolver.resolve_tenant!(resource, record, :upsert)

    # Native MERGE upsert by primary key (no explicit upsert_identity — ash_arcadic's upsert
    # falls back to the primary key). `upsert_fields` are the source-mapped columns to SET
    # ON MATCH, so an unchanged-TOAST column (absent from `record`) is left untouched.
    Ash.create!(resource, inputs,
      action: create_action(resource),
      upsert?: true,
      upsert_fields: upsert_fields,
      tenant: tenant,
      authorize?: config.authorize?
    )

    :ok
  rescue
    e -> reraise scrub(e, resource, :upsert), __STACKTRACE__
  end

  defp destroy_by_pk(config, resource, old_record) do
    pk_values = Resolver.pk_values(resource, old_record)

    # Fail closed on a missing PK BEFORE building the filter: a nil PK value would produce
    # `id == nil`, which matches 0 rows and would silently "succeed" — losing the
    # no-silent-lost-delete contract. Value-free (no record, no value).
    if Enum.any?(pk_values, fn {_k, v} -> is_nil(v) end) do
      raise Error.exception(reason: :missing_primary_key, resource: resource, op: :destroy)
    end

    tenant = Resolver.resolve_tenant!(resource, old_record, :destroy)
    query = Ash.Query.do_filter(resource, pk_values)

    # One atomic `MATCH ... WHERE pk DETACH DELETE n` (the bulk destroy_query path).
    # `transaction: false` joins the enclosing apply session. Tenant scopes the delete
    # (fail-closed, resolved above). A 0-row match (already-absent) is `:ok` (idempotent).
    Ash.bulk_destroy!(query, destroy_action(resource), %{},
      strategy: [:atomic, :stream],
      transaction: false,
      tenant: tenant,
      authorize?: config.authorize?,
      return_errors?: true
    )

    :ok
  rescue
    e -> reraise scrub(e, resource, :destroy), __STACKTRACE__
  end

  defp truncate(resource) do
    case Info.on_truncate(resource) do
      :halt ->
        raise Error.exception(reason: :truncate_halt, resource: resource, op: :truncate)

      :mirror ->
        clear_label!(resource, :truncate)
    end
  rescue
    e -> reraise scrub(e, resource, :truncate), __STACKTRACE__
  end

  @doc false
  # Tenant-BLIND whole-label delete, SHARED by the truncate `:mirror` path (`op: :truncate`)
  # and the sink's snapshot `first_for_table?` redo-clear (`op: :snapshot`). A Postgres
  # TRUNCATE / a snapshot dump is tenant-BLIND, and a tenant-scoped destroy would need a
  # tenant neither carries. The label is an allowlist-validated identifier (Rule 1: labels
  # are never `$params`; the VALIDATED label is interpolated, never a row value).
  # `base_write_conn/1` resolves the base-database session write conn (fail-closed
  # `:tenant_required` for `:context`, which a replicant resource never is); the raw
  # `DETACH DELETE` runs IN that session so it is atomic with the sibling writes and the
  # checkpoint upsert. Raises a value-free `Error` on failure (`op` labels the caller).
  # (On the in-session path — the only real path, `base_write_conn/1` returns the open
  # session — raw `Arcadic.command` is identical to the data layer's `write_command/3`: the
  # latter passes a session conn straight through, its autocommit retry applying only to
  # non-session conns, so there is nothing to reuse.)
  @spec clear_label!(Ash.Resource.t(), atom()) :: :ok
  def clear_label!(resource, op) do
    label = resource |> DataLayerInfo.label() |> AshArcadic.Identifier.validate!()

    case AshArcadic.DataLayer.base_write_conn(resource) do
      {:ok, conn} ->
        case Arcadic.command(conn, "MATCH (n:#{label}) DETACH DELETE n", %{}) do
          {:ok, _rows} ->
            :ok

          {:error, _error} ->
            raise Error.exception(reason: :sink_failed, resource: resource, op: op)
        end

      {:error, _reason} ->
        raise Error.exception(reason: :sink_failed, resource: resource, op: op)
    end
  end

  # Reject a degenerate identity before the upsert: a resource with no primary key, or a
  # record missing any PK value, would MERGE on an empty/partial identity and clobber
  # unrelated vertices. Value-free — never the record or the missing value.
  defp reject_empty_identity!(resource, record) do
    pk = Resolver.primary_key(resource)
    values = Resolver.pk_values(resource, record)

    if pk == [] or Enum.any?(values, fn {_k, v} -> is_nil(v) end) do
      raise Error.exception(reason: :empty_identity, resource: resource, op: :upsert)
    end
  end

  # Inner (per-change) layer: convert a RAISE within one change to a value-free Error with the
  # right op. An already value-free `AshArcadic.Replicant.Error` (a guard raise) passes through
  # with its reason intact; any OTHER exception (an Ash error carrying changeset input, an
  # `Arcadic.Error`/`Jason.EncodeError` on nested bytes) is replaced by a static `:sink_failed`
  # Error — the original exception's contents are NEVER inspected (`project_redaction_fail_path_exception_leak`).
  # (A data-layer write failure arrives as a rollback THROW, which a `rescue` does NOT catch —
  # that path is handled at the `apply_transaction/2` boundary by `boundary_error/1`.)
  defp scrub(%Error{} = error, _resource, _op), do: error

  defp scrub(_exception, resource, op),
    do: Error.exception(reason: :sink_failed, resource: resource, op: op)

  @doc false
  # The value-free boundary, SHARED by `apply_transaction/2` and the sink's snapshot callbacks
  # (`AshArcadic.Replicant.Sink.Impl`) — a single source of truth for a security-critical
  # boundary. Lets only PROVABLY value-free terms cross: our own `AshArcadic.Replicant.Error`
  # (atoms only), and a bare structural `AshArcadic.Errors.*` data-layer error (value-free by
  # AGENTS.md Rule 4). An `Ash.Error` CONTAINER carries the changeset/query (the source row) —
  # value-BEARING — so it never passes through: if it wraps only bare value-free data-layer
  # errors, surface the first one (preserving the value-free diagnostic); otherwise, and for
  # ANY unrecognized term, fail closed to a static `:sink_failed` (never trust an unrecognized
  # error to be value-free).
  @spec boundary_error(term()) :: struct()
  def boundary_error(%Error{} = error), do: error
  def boundary_error(%AshArcadic.Errors.CreateFailed{} = error), do: error
  def boundary_error(%AshArcadic.Errors.UpdateFailed{} = error), do: error
  def boundary_error(%AshArcadic.Errors.QueryFailed{} = error), do: error
  def boundary_error(%AshArcadic.Errors.UnsupportedFilter{} = error), do: error

  def boundary_error(%{errors: [_ | _] = errors}) do
    if Enum.all?(errors, &data_layer_value_free?/1), do: hd(errors), else: sink_failed()
  end

  def boundary_error(_other), do: sink_failed()

  defp data_layer_value_free?(%AshArcadic.Errors.CreateFailed{}), do: true
  defp data_layer_value_free?(%AshArcadic.Errors.UpdateFailed{}), do: true
  defp data_layer_value_free?(%AshArcadic.Errors.QueryFailed{}), do: true
  defp data_layer_value_free?(%AshArcadic.Errors.UnsupportedFilter{}), do: true
  defp data_layer_value_free?(_other), do: false

  defp sink_failed, do: Error.exception(reason: :sink_failed)

  defp pk_changed?(resource, %Replicant.Change{record: record, old_record: old})
       when is_map(old) do
    Resolver.pk_values(resource, record) != Resolver.pk_values(resource, old)
  end

  defp pk_changed?(_resource, _change), do: false

  defp create_action(resource), do: Ash.Resource.Info.primary_action!(resource, :create).name
  defp destroy_action(resource), do: Ash.Resource.Info.primary_action!(resource, :destroy).name
end
