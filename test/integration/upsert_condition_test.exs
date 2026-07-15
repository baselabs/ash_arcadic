defmodule AshArcadic.Integration.UpsertConditionTest do
  @moduledoc """
  `upsert_condition` support (S9P2 backlog CV-1 — previously the condition was SILENTLY IGNORED:
  every conditional upsert clobbered the matched row). Semantics mirror Ash's reference (ETS/
  ash_postgres): the condition gates the ON-MATCH update against the EXISTING row's values.

    * condition TRUE on the matched row  → update applies.
    * condition FALSE on the matched row → the update is SKIPPED: single-row default →
      `Ash.Error.Changes.StaleRecord`; with `return_skipped_upsert?: true` → `{:ok, existing}`
      flagged `__metadata__.upsert_skipped`. In BULK (without return_skipped_upsert?) a skipped
      row is OMITTED from the returned records (Ash's own bulk-fallback semantics), never an error.
    * no matched row → plain CREATE (the condition gates ON MATCH only).

  Fail-closed tenancy holds: the conditional flow matches through the tenant-scoped identity, so
  another tenant's same-PK row is neither evaluated nor mutated.
  """
  use AshArcadic.Test.IntegrationCase
  require Ash.Expr

  alias AshArcadic.Test.{AttributeDoc, UpsertThing}

  setup %{admin: admin} do
    on_exit(fn ->
      Arcadic.command!(admin, "MATCH (n:UpsertThing) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:AttributeDoc) DETACH DELETE n")
    end)

    :ok
  end

  defp upsert(params, opts \\ []) do
    UpsertThing
    |> Ash.Changeset.for_create(:upsert, params, opts)
    |> Ash.create(opts)
  end

  defp fetch!(code) do
    Ash.get!(UpsertThing, code)
  end

  test "condition FALSE on the matched row → StaleRecord, row untouched (was: silent clobber)" do
    {:ok, _} = upsert(%{code: "a", name: "orig", version: 10})

    result =
      upsert(%{code: "a", name: "hacked", version: 99},
        upsert_condition: Ash.Expr.expr(version > 50)
      )

    assert {:error, error} = result

    assert Enum.any?(
             List.wrap(error) ++ List.wrap(Map.get(error, :errors)),
             &match?(%Ash.Error.Changes.StaleRecord{}, &1)
           )

    # The existing row is untouched — the ON MATCH update did NOT apply.
    row = fetch!("a")
    assert row.name == "orig"
    assert row.version == 10
  end

  test "condition TRUE on the matched row → the update applies" do
    {:ok, _} = upsert(%{code: "a", name: "orig", version: 60})

    {:ok, updated} =
      upsert(%{code: "a", name: "bumped", version: 61},
        upsert_condition: Ash.Expr.expr(version > 50)
      )

    assert updated.name == "bumped"
    assert fetch!("a").version == 61
  end

  test "condition FALSE + return_skipped_upsert?: true → existing row returned, flagged, unchanged" do
    {:ok, _} = upsert(%{code: "a", name: "orig", version: 10})

    {:ok, skipped} =
      upsert(%{code: "a", name: "hacked", version: 99},
        upsert_condition: Ash.Expr.expr(version > 50),
        return_skipped_upsert?: true
      )

    assert skipped.__metadata__[:upsert_skipped] == true
    # The RETURNED record is the EXISTING row (not the attempted values), and the DB is unchanged.
    assert skipped.name == "orig"
    assert fetch!("a").name == "orig"
  end

  test "no matched row → the condition gates ON MATCH only; a plain CREATE happens" do
    {:ok, created} =
      upsert(%{code: "fresh", name: "new", version: 1},
        upsert_condition: Ash.Expr.expr(version > 50)
      )

    assert created.name == "new"
    assert fetch!("fresh").version == 1
  end

  test "tenancy: another tenant's same-PK row is neither evaluated nor mutated" do
    # org2 owns id "x" (amount 10). org1's conditional upsert of id "x" must NOT see org2's row:
    # org1 has no "x" → CREATE (not a skip against org2's amount), and org2's row stays untouched.
    {:ok, _} =
      AttributeDoc
      |> Ash.Changeset.for_create(:upsert, %{id: "x", name: "org2-row", amount: 10},
        tenant: "org2"
      )
      |> Ash.create()

    {:ok, created} =
      AttributeDoc
      |> Ash.Changeset.for_create(:upsert, %{id: "x", name: "org1-row", amount: 99},
        tenant: "org1",
        upsert_condition: Ash.Expr.expr(amount > 50)
      )
      |> Ash.create(upsert_condition: Ash.Expr.expr(amount > 50))

    assert created.name == "org1-row"

    {:ok, [org2_row]} = AttributeDoc |> Ash.Query.for_read(:read) |> Ash.read(tenant: "org2")
    assert org2_row.name == "org2-row"
    assert org2_row.amount == 10
  end

  test "bulk upsert with a condition: matched-true updated, matched-false OMITTED, new created" do
    {:ok, _} = upsert(%{code: "keep", name: "orig", version: 10})
    {:ok, _} = upsert(%{code: "bump", name: "orig", version: 60})

    rows = [
      %{code: "keep", name: "clobber?", version: 99},
      %{code: "bump", name: "bumped", version: 99},
      %{code: "new", name: "created", version: 1}
    ]

    result =
      Ash.bulk_create(rows, UpsertThing, :upsert,
        upsert_condition: Ash.Expr.expr(version > 50),
        upsert_fields: [:name, :version],
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :success
    returned = result.records |> Enum.map(& &1.code) |> Enum.sort()

    # "keep" failed the condition → omitted from records (Ash bulk-skip semantics), row untouched.
    assert returned == ["bump", "new"]
    assert fetch!("keep").name == "orig"
    assert fetch!("bump").name == "bumped"
    assert fetch!("new").name == "created"
  end

  test "bulk + return_skipped_upsert?: true → the skipped row IS returned, flagged, unchanged" do
    {:ok, _} = upsert(%{code: "keep", name: "orig", version: 10})

    result =
      Ash.bulk_create(
        [%{code: "keep", name: "clobber?", version: 99}],
        UpsertThing,
        :upsert,
        upsert_condition: Ash.Expr.expr(version > 50),
        upsert_fields: [:name, :version],
        return_skipped_upsert?: true,
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :success
    assert [rec] = result.records
    assert rec.__metadata__[:upsert_skipped] == true
    assert fetch!("keep").name == "orig"
  end
end
