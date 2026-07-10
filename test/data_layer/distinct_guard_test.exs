defmodule AshArcadic.DataLayer.DistinctGuardTest do
  use ExUnit.Case, async: true

  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Errors.QueryFailed
  alias AshArcadic.Query

  defp q, do: %Query{resource: AshArcadic.Test.Basic, label: :Person}

  test "distinct on a stored non-sensitive field is accepted and stashed" do
    assert {:ok, %Query{distinct: [{:name, :asc}]}} =
             DL.distinct(q(), [{:name, :asc}], AshArcadic.Test.Basic)
  end

  test "distinct on a SENSITIVE field fails closed value-free (ciphertext won't dedup equal plaintext)" do
    assert {:error, %QueryFailed{} = err} =
             DL.distinct(q(), [{:secret, :asc}], AshArcadic.Test.Basic)

    # Exact static reason — pins value-freedom (field atom only) and message stability.
    assert Exception.message(err) =~ "distinct over sensitive field secret is unsupported"
    assert Exception.message(err) =~ "secret"
  end

  test "distinct on a :decimal field is accepted at this layer (dedup is equality; Ash rejects it upstream)" do
    # Through Ash.Query.distinct/2 this entry never arrives (Sort.process → type_sortable? →
    # UnsortableField, live-probed); at the data layer dedup is equality, so byte order is irrelevant.
    assert {:ok, %Query{distinct: [{:amount, :asc}]}} =
             DL.distinct(q(), [{:amount, :asc}], AshArcadic.Test.Basic)
  end

  test "distinct normalizes the %Ash.Resource.Attribute{} struct form into the stash" do
    assert {:ok, %Query{distinct: [{:name, :asc}]}} =
             DL.distinct(
               q(),
               [{struct(Ash.Resource.Attribute, name: :name), :asc}],
               AshArcadic.Test.Basic
             )
  end

  test "distinct on a NON-STORED (skipped) field fails closed value-free" do
    assert {:error, %QueryFailed{}} =
             DL.distinct(q(), [{:computed, :asc}], AshArcadic.Test.Basic)
  end

  test "distinct on a CALCULATION/expression entry fails closed value-free" do
    calc_entry = {struct(Ash.Query.Calculation, name: :fullname), :asc}

    assert {:error, %QueryFailed{}} =
             DL.distinct(q(), [calc_entry], AshArcadic.Test.Basic)
  end

  test "distinct_sort on a stored field is accepted" do
    assert {:ok, %Query{distinct_sort: [{:name, :desc}]}} =
             DL.distinct_sort(q(), [{:name, :desc}], AshArcadic.Test.Basic)
  end

  test "distinct_sort normalizes the %Ash.Resource.Attribute{} struct form into the stash" do
    assert {:ok, %Query{distinct_sort: [{:name, :desc}]}} =
             DL.distinct_sort(
               q(),
               [{struct(Ash.Resource.Attribute, name: :name), :desc}],
               AshArcadic.Test.Basic
             )
  end

  test "distinct_sort rejects an unknown direction qualifier value-free (render would coerce to ASC)" do
    # Ash.Query.distinct_sort/3 appends RAW entries (no Sort.process → no InvalidSortOrder
    # upstream, unlike sort/distinct) — this guard is the only line of defense.
    assert {:error, %QueryFailed{} = err} =
             DL.distinct_sort(q(), [{:name, :bogus}], AshArcadic.Test.Basic)

    assert Exception.message(err) =~
             "distinct direction for field name is not a supported sort order"

    refute Exception.message(err) =~ "bogus"
  end

  test "distinct_sort ACCEPTS every render-supported nil-placement qualifier (no over-reject)" do
    # Allowlist-completeness tripwire: the clamp must admit the full six-qualifier set the
    # render handles (order_by_expr/order_dir), not just :asc/:desc.
    for dir <- [:asc, :asc_nils_first, :asc_nils_last, :desc, :desc_nils_first, :desc_nils_last] do
      assert {:ok, %Query{distinct_sort: [{:name, ^dir}]}} =
               DL.distinct_sort(q(), [{:name, dir}], AshArcadic.Test.Basic)
    end
  end

  test "distinct rejects an unknown direction qualifier too (shared clamp, defense-in-depth)" do
    assert {:error, %QueryFailed{}} =
             DL.distinct(q(), [{:name, :bogus}], AshArcadic.Test.Basic)
  end

  test "a relationship-path %Ash.Query.Ref{} entry fails closed value-free (rel-path distinct is a non-goal)" do
    # Through the Ash API a rel-path entry arrives wrapped in %Ash.Query.Calculation{}
    # (Sort.process); this pins the same :expression catch-all for the DIRECT ingress shape.
    ref_entry = {struct(Ash.Query.Ref, attribute: :name, relationship_path: [:author]), :asc}

    assert {:error, %QueryFailed{} = err} = DL.distinct(q(), [ref_entry], AshArcadic.Test.Basic)
    refute Exception.message(err) =~ "author"
  end

  test "hand-crafted %Attribute{} entries with NON-ATOM names fail closed value-free (no raw crash)" do
    # Ash.Query.distinct_sort/3 appends RAW caller entries; without the is_atom guard these
    # shapes escape as FunctionClauseError / Protocol.UndefinedError carrying the caller's own
    # term (closeout security note) — they must die in the static :expression reject instead.
    for {name, dir} <- [{"x y", :asc}, {%{}, :bogus}, {"strname", :bogus}] do
      entry = {struct(Ash.Resource.Attribute, name: name), dir}

      assert {:error, %QueryFailed{} = err} =
               DL.distinct_sort(q(), [entry], AshArcadic.Test.Basic)

      msg = Exception.message(err)
      refute msg =~ "x y"
      refute msg =~ "strname"
    end
  end

  test "distinct_sort on a :binary field fails closed (base64 order != byte order)" do
    assert {:error, %QueryFailed{}} =
             DL.distinct_sort(q(), [{:secret, :asc}], AshArcadic.Test.Basic)
  end

  test "distinct_sort on a :decimal field fails closed (lexicographic != numeric)" do
    assert {:error, %QueryFailed{}} =
             DL.distinct_sort(q(), [{:amount, :asc}], AshArcadic.Test.Basic)
  end
end
