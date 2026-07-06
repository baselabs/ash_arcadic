defmodule AshArcadic.TraversalAggregateTest do
  use ExUnit.Case, async: true

  alias Ash.Query.Aggregate
  alias AshArcadic.TraversalAggregate

  # Loaded destination records are already decoded Ash structs (Traverse Read B), already
  # filtered/authorized/deduped/sorted. TraversalAggregate.fold/3 just folds them per kind.
  defmodule Dst do
    @moduledoc false
    defstruct [:id, :amount, :name, :at]
  end

  # types map: field -> {Ash.Type, constraints} (drives guard_field + min/max comparator)
  defp types do
    %{
      amount: {Ash.Type.Integer, []},
      name: {Ash.Type.String, []},
      at: {Ash.Type.UtcDatetime, []},
      id: {Ash.Type.String, []}
    }
  end

  defp agg(kind, field, opts \\ []) do
    %Aggregate{
      kind: kind,
      field: field,
      uniq?: Keyword.get(opts, :uniq?, false),
      include_nil?: Keyword.get(opts, :include_nil?, false),
      default_value: Keyword.get(opts, :default, Aggregate.default_value(kind)),
      name: :agg,
      query: nil
    }
  end

  defp recs do
    [
      %Dst{id: "a", amount: 10, name: "A", at: ~U[2026-01-01 00:00:00Z]},
      %Dst{id: "b", amount: 20, name: "B", at: ~U[2026-03-01 00:00:00Z]},
      %Dst{id: "c", amount: 30, name: "C", at: ~U[2026-02-01 00:00:00Z]}
    ]
  end

  test "count (no field) = record length" do
    assert TraversalAggregate.fold(recs(), agg(:count, nil), types()) == {:ok, 3}
  end

  test "count (field) skips nils; uniq? distincts by value" do
    withnil = recs() ++ [%Dst{id: "d", amount: nil}]
    assert TraversalAggregate.fold(withnil, agg(:count, :amount), types()) == {:ok, 3}
    dup = recs() ++ [%Dst{id: "e", amount: 10}]
    assert TraversalAggregate.fold(dup, agg(:count, :amount, uniq?: true), types()) == {:ok, 3}
  end

  test "sum / avg / min / max over integer field" do
    assert TraversalAggregate.fold(recs(), agg(:sum, :amount), types()) == {:ok, 60}
    assert TraversalAggregate.fold(recs(), agg(:avg, :amount), types()) == {:ok, 20.0}
    assert TraversalAggregate.fold(recs(), agg(:min, :amount), types()) == {:ok, 10}
    assert TraversalAggregate.fold(recs(), agg(:max, :amount), types()) == {:ok, 30}
  end

  test "min/max over a datetime field uses chronological (not term) comparison" do
    # term order of the DateTime maps is NOT chronological; must compare via DateTime.
    assert TraversalAggregate.fold(recs(), agg(:min, :at), types()) ==
             {:ok, ~U[2026-01-01 00:00:00Z]}

    assert TraversalAggregate.fold(recs(), agg(:max, :at), types()) ==
             {:ok, ~U[2026-03-01 00:00:00Z]}
  end

  test "first = head in read order (Read B already applied sort); empty -> default" do
    assert TraversalAggregate.fold(recs(), agg(:first, :name), types()) == {:ok, "A"}
    assert TraversalAggregate.fold([], agg(:first, :name), types()) == {:ok, nil}
  end

  test "first honors include_nil?: leading-nil head returns nil (true) vs first non-nil (false)" do
    withnil = [%Dst{id: "z", name: nil}] ++ recs()

    assert TraversalAggregate.fold(withnil, agg(:first, :name, include_nil?: true), types()) ==
             {:ok, nil}

    assert TraversalAggregate.fold(withnil, agg(:first, :name), types()) == {:ok, "A"}
  end

  test "list drops nils by default; include_nil? preserves; uniq? distincts" do
    withnil = recs() ++ [%Dst{id: "d", name: nil}]
    assert TraversalAggregate.fold(withnil, agg(:list, :name), types()) == {:ok, ["A", "B", "C"]}

    assert TraversalAggregate.fold(withnil, agg(:list, :name, include_nil?: true), types()) ==
             {:ok, ["A", "B", "C", nil]}
  end

  test "exists true / false" do
    assert TraversalAggregate.fold(recs(), agg(:exists, nil), types()) == {:ok, true}
    assert TraversalAggregate.fold([], agg(:exists, nil), types()) == {:ok, false}
  end

  test "empty / all-nil-field set -> struct default_value" do
    assert TraversalAggregate.fold([], agg(:sum, :amount, default: 0), types()) == {:ok, 0}
    assert TraversalAggregate.fold([], agg(:sum, :amount), types()) == {:ok, nil}
    allnil = [%Dst{id: "x", amount: nil}]
    assert TraversalAggregate.fold(allnil, agg(:sum, :amount), types()) == {:ok, nil}
  end

  test "guard: sum over a non-numeric (:string) field fails closed value-free" do
    assert {:error, {:unaggregatable, :name, :sum}} =
             TraversalAggregate.fold(recs(), agg(:sum, :name), types())
  end

  test "guard: list over :binary (sensitive) fails closed value-free" do
    bin_types = Map.put(types(), :secret, {Ash.Type.Binary, []})
    recs = [%Dst{id: "a"} |> Map.put(:secret, "cipher")]

    assert {:error, {:unaggregatable, :secret, :list}} =
             TraversalAggregate.fold(recs, agg(:list, :secret), bin_types)
  end

  test "guard: include_nil? on list is HONORED (not fail-closed like the Slice-3 flat path)" do
    assert {:ok, _} =
             TraversalAggregate.fold(recs(), agg(:list, :name, include_nil?: true), types())
  end
end
