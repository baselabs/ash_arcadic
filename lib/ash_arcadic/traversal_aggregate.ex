defmodule AshArcadic.TraversalAggregate do
  @moduledoc """
  Post-authorization Elixir fold for traversal aggregates (Slice 4). Folds a source's
  ALREADY-authorized, node-deduped, tenant-scoped, filtered, sorted destination records
  (from `Traverse.load`'s Read B) into one aggregate value — never a DB-side aggregate
  (which would count policy-denied nodes and double-count multi-path nodes for sum/avg).

  `guard_field/2` (reused from `AshArcadic.Aggregate`) runs BEFORE any fold — a value-reading
  aggregate over non-numeric/non-orderable/`:binary` (sensitive) storage fails closed value-free.
  Records are already decoded Ash structs, so field values carry their proper Elixir type (no
  re-coerce). `min`/`max` over date/time use the type's `compare/2` (term order of a DateTime
  map is NOT chronological). `include_nil?` is HONORED for `list`/`first` (Elixir null control),
  a capability gain over the Slice-3 flat path (Cypher `collect` drops nulls). The fold is wrapped
  value-free: any protocol/arithmetic error returns `{:error, :aggregate_fold_failed}`, never a value.
  """

  alias AshArcadic.Aggregate

  @spec fold([map()], Ash.Query.Aggregate.t(), %{atom() => {Ash.Type.t(), keyword()}}) ::
          {:ok, term()} | {:error, term()}
  def fold(records, %Ash.Query.Aggregate{} = agg, types) do
    # guard_field/2 rejects include_nil?:true for list/first — a FLAT/Cypher-collect-drops-nulls
    # limitation (aggregate.ex:44-46), NOT a storage-type constraint. The Elixir fold preserves nulls
    # natively (list_values/3), so neutralize include_nil? for the GUARD call only: the storage guards
    # ({:unaggregatable,_,_} / :expression_field / {:unsupported_kind,_}) still apply; do_fold below
    # gets the ORIGINAL agg and honors the real include_nil?. (Clause 4 is guard_field/2's ONLY
    # include_nil?-reading clause — verified aggregate.ex:31-65 — so this is exact, not a workaround.)
    case Aggregate.guard_field(%{agg | include_nil?: false}, types) do
      :ok -> safe_fold(records, agg, types)
      {:error, _} = err -> err
    end
  end

  # Value-free wrapper (Rule 4): a to_string/inspect/arith error over a mixed set must not carry
  # a value across the callback boundary. The guard already rejected unaggregatable fields, so a
  # raise here is defense-in-depth.
  defp safe_fold(records, agg, types) do
    {:ok, do_fold(records, agg, types)}
  rescue
    _ -> {:error, :aggregate_fold_failed}
  end

  defp do_fold(records, %Ash.Query.Aggregate{kind: :count, field: nil}, _types),
    do: length(records)

  defp do_fold(records, %Ash.Query.Aggregate{kind: :count, field: f, uniq?: true}, _types),
    do: records |> field_values(f) |> Enum.uniq() |> length()

  defp do_fold(records, %Ash.Query.Aggregate{kind: :count, field: f}, _types),
    do: records |> field_values(f) |> length()

  defp do_fold(records, %Ash.Query.Aggregate{kind: :exists}, _types), do: records != []

  defp do_fold(records, %Ash.Query.Aggregate{kind: :list, field: f} = agg, _types) do
    vals = list_values(records, f, agg.include_nil?)
    vals = if agg.uniq?, do: Enum.uniq(vals), else: vals
    if vals == [], do: agg.default_value, else: vals
  end

  # include_nil?: true → the LITERAL head record's field value (may be nil), matching Ash's :first
  # contract (ets.ex:932-940). Read B already applied sort, so head = first in read order.
  defp do_fold(
         records,
         %Ash.Query.Aggregate{kind: :first, field: f, include_nil?: true} = agg,
         _types
       ) do
    case records do
      [] -> agg.default_value
      [record | _] -> Map.get(record, f)
    end
  end

  defp do_fold(records, %Ash.Query.Aggregate{kind: :first, field: f} = agg, _types) do
    case field_values(records, f) do
      [] -> agg.default_value
      [v | _] -> v
    end
  end

  defp do_fold(records, %Ash.Query.Aggregate{kind: kind, field: f} = agg, types)
       when kind in [:sum, :avg, :min, :max] do
    case field_values(records, f) do
      [] -> agg.default_value
      vals -> reduce(kind, vals, comparator(f, types))
    end
  end

  # count/sum/avg/min/max/first skip nulls (Ash contract). list honors include_nil?.
  defp field_values(records, field),
    do: records |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1)

  defp list_values(records, field, true), do: Enum.map(records, &Map.get(&1, field))
  defp list_values(records, field, _false), do: field_values(records, field)

  defp reduce(:sum, vals, _cmp), do: Enum.sum(vals)
  defp reduce(:avg, vals, _cmp), do: Enum.sum(vals) / length(vals)
  defp reduce(:min, vals, nil), do: Enum.min(vals)
  defp reduce(:max, vals, nil), do: Enum.max(vals)
  defp reduce(:min, vals, cmp), do: Enum.min(vals, cmp)
  defp reduce(:max, vals, cmp), do: Enum.max(vals, cmp)

  # min/max over date/time types must compare chronologically, not by DateTime-map term order.
  # numeric/string use default term comparison (nil comparator).
  defp comparator(field, types) do
    case Map.get(types, field) do
      {type, constraints} ->
        case Ash.Type.storage_type(type, constraints) do
          t when t in [:utc_datetime, :utc_datetime_usec] -> DateTime
          t when t in [:datetime, :naive_datetime, :naive_datetime_usec] -> NaiveDateTime
          :date -> Date
          t when t in [:time, :time_usec] -> Time
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
