defmodule AshArcadic.ReplicantCheckpoint do
  @moduledoc """
  `use AshArcadic.ReplicantCheckpoint, domain: MyApp.Domain, client: MyApp.ArcadicClient`
  injects the ArcadeDB-resident checkpoint vertex resource (label `:ReplicantCheckpoint`)
  — one row per replication slot, holding the last durably-applied `last_commit_lsn`
  watermark — plus the `for_slot/1` and `upsert_lsn/2` seam helpers the sink's apply
  step (`AshArcadic.ReplicantSink`) calls directly.

  The sink upserts this row in the SAME `Ash.transaction` as the mirrored data writes,
  which is what gives effect-once (dup = 0) semantics: the watermark advance and the
  data writes commit atomically in one ArcadeDB session.

  **The `client:` opt MUST resolve to the SAME ArcadeDB database as the mirrored
  resources.** This resource is deliberately non-tenant-scoped (no `multitenancy`
  block) — nothing here verifies the single-database precondition (unlike
  `AshArcadic.Replicant`'s mirror-resource verifier: this is not a mirror resource).
  A `client:` pointed at a different database than the mirrored resources breaks the
  same-transaction guarantee — the checkpoint upsert becomes a cross-database write,
  which `AshArcadic.Transaction.resolve_conn/2` fails closed on
  (`:cross_database_transaction`) rather than silently splitting the commit. The
  consumer is responsible for wiring this correctly.

  **Seam-lock (design §12 "checkpoint writes seam-only").** Ordinary writes are
  forbidden by an `Ash.Policy.Authorizer` policy (`forbid_if always()`). The injected
  `for_slot/1` and `upsert_lsn/2` helpers are the only sanctioned read/write path —
  they bypass the policy with `authorize?: false`. Any other caller (e.g. a bare
  `Ash.create/2` without `authorize?: false`) is rejected.
  """

  @doc false
  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    client = Keyword.fetch!(opts, :client)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshArcadic.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      arcade do
        label(:ReplicantCheckpoint)
        client(unquote(client))
      end

      attributes do
        attribute :slot_name, :string do
          primary_key? true
          allow_nil? false
        end

        # `Replicant.lsn/0` is a non_neg_integer (uint64) watermark. Stored and gated
        # as an INTEGER, never :string — a :string store + the `<=` replay gate
        # compares integer-to-binary lexicographically and would silently apply
        # nothing (or apply out of order) for multi-digit LSNs (Ch5/D8).
        attribute :last_commit_lsn, :integer do
          allow_nil? false
        end

        update_timestamp :updated_at
      end

      identities do
        identity :unique_slot, [:slot_name]
      end

      actions do
        defaults [:read]

        create :upsert do
          upsert? true
          upsert_identity :unique_slot
          accept [:slot_name, :last_commit_lsn]
        end
      end

      policies do
        policy always() do
          forbid_if always()
        end
      end

      @doc """
      The durably-applied `last_commit_lsn` watermark for `slot_name`, or `nil` when
      no checkpoint row exists yet for that slot — the never-applied case. T5's replay
      gate (`is_integer(stored) and lsn <= stored`) must APPLY on `nil`, not skip, so
      this never defaults a missing row to `0`/`""`. Bypasses the seam-lock with
      `authorize?: false` — this IS the seam.
      """
      @spec for_slot(String.t()) :: integer() | nil
      def for_slot(slot_name) do
        __MODULE__
        |> Ash.get!(slot_name, authorize?: false, not_found_error?: false)
        |> case do
          nil -> nil
          checkpoint -> checkpoint.last_commit_lsn
        end
      end

      @doc """
      Upserts the checkpoint row for `slot_name` to `last_commit_lsn`. Bypasses the
      seam-lock with `authorize?: false` — this IS the seam. Called from inside the
      apply transaction (T5): passes no options that would open a separate
      connection, so the write joins the enclosing `Ash.transaction` session and
      commits atomically with the mirrored data.
      """
      @spec upsert_lsn(String.t(), integer()) :: :ok
      def upsert_lsn(slot_name, last_commit_lsn) do
        __MODULE__
        |> Ash.Changeset.for_create(
          :upsert,
          %{slot_name: slot_name, last_commit_lsn: last_commit_lsn},
          authorize?: false
        )
        |> Ash.create!()

        :ok
      end
    end
  end
end
