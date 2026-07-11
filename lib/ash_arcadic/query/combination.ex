defmodule AshArcadic.Query.Combination do
  @moduledoc false
  # `combination_of` support for AshArcadic. `native?/1` selects native UNION/UNION ALL push-down
  # (every branch union-family) vs the in-memory PK-keyed set-op fold (any intersect/except — ArcadeDB
  # has no INTERSECT/EXCEPT, live-verified parse error). `rekey_branch/3` namespaces a branch's rendered
  # $param refs so multiple branches can share ONE UNION statement's single params map. Per-branch
  # tenancy is enforced by AshArcadic.DataLayer.combination_of/3 BEFORE a branch reaches here.

  @union_family [:base, :union, :union_all]

  @doc "True when every branch type is union-family → native UNION push-down; else in-memory fold."
  def native?(combination_of), do: Enum.all?(combination_of, fn {t, _q} -> t in @union_family end)

  @doc false
  # In-memory PK-keyed set-op fold. `branch_results :: [{:base, [record]} | {type, [record]}]` in chain
  # order — the FIRST branch MUST be `:base` (Ash gates only the first entry's type; a mid-chain `:base`
  # is constructible and reaches here). This fold keys on PRIMARY KEY ONLY under the whole-vertex model
  # (combinations return whole vertices, no field-projection select): per-branch tenant scoping means one
  # tenant, so a PK is unique WITHIN the set (:attribute PKs collide ACROSS tenants, never within one),
  # making PK identity a faithful set key. It is UNSOUND for branches carrying DISTINGUISHING per-branch
  # `calculations` (Ash's combination fieldset may include them, read.ex:1224 — two same-PK rows can be
  # legitimately distinct); that is out of the supported model and the later integration must fail closed
  # on it.
  def combine([{:base, base} | rest], pk_fields) do
    Enum.reduce(rest, base, fn {type, results}, acc ->
      apply_op(type, acc, results, pk_fields)
    end)
  end

  # FAIL CLOSED value-free: a non-`:base` first branch (or an empty chain) reached here. Ash rejects a
  # non-`:base` first entry upstream (read.ex:1214) and AshArcadic.DataLayer.combination_of/3 rejects it
  # again, so this is direct-invocation defense-in-depth — a clear message, never a FunctionClauseError
  # whose blamed args would carry the decoded record lists.
  def combine(_branch_results, _pk_fields) do
    raise ArgumentError, "combination_of: the first branch must be :base"
  end

  # FAIL CLOSED: a mid-chain `:base` would REPLACE the accumulator, silently dropping every prior branch.
  # Ash's validate_combinations only rejects a non-`:base` FIRST entry (read.ex:1214), so this is
  # reachable. Value-free message (no record data), symmetric with the native path's loud reject.
  defp apply_op(:base, _acc, _results, _pk) do
    raise ArgumentError, "combination_of: :base is only valid as the first branch"
  end

  defp apply_op(:union_all, acc, results, _pk), do: acc ++ results

  defp apply_op(:union, acc, results, pk) do
    seen = MapSet.new(acc, &pk_key(&1, pk))
    acc ++ Enum.reject(results, &MapSet.member?(seen, pk_key(&1, pk)))
  end

  defp apply_op(:intersect, acc, results, pk) do
    keys = MapSet.new(results, &pk_key(&1, pk))
    Enum.filter(acc, &MapSet.member?(keys, pk_key(&1, pk)))
  end

  defp apply_op(:except, acc, results, pk) do
    keys = MapSet.new(results, &pk_key(&1, pk))
    Enum.reject(acc, &MapSet.member?(keys, pk_key(&1, pk)))
  end

  defp pk_key(record, pk_fields), do: Enum.map(pk_fields, &Map.get(record, &1))

  @doc false
  # Rewrites a branch's rendered filter clauses + params into a disjoint `b<index>_<key>` namespace.
  # Replaces the LONGEST keys first so `$param1` is never a partial match inside `$param10`.
  def rekey_branch(filters, params, index) do
    prefix = "b#{index}_"
    keys = params |> Map.keys() |> Enum.sort_by(&byte_size/1, :desc)

    rekeyed_filters =
      Enum.map(filters, fn clause ->
        Enum.reduce(keys, clause, fn k, c -> String.replace(c, "$#{k}", "$#{prefix}#{k}") end)
      end)

    {rekeyed_filters, Map.new(params, fn {k, v} -> {prefix <> k, v} end)}
  end
end
