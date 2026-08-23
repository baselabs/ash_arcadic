defmodule AshArcadic.Integration.UnicodeRoundtripTest do
  @moduledoc """
  Non-ASCII and escaping round-trips through the LIVE engine — write → ArcadeDB →
  read decode (`Cast.load_value`). The corpus deliberately includes the classes that
  break naive codecs: CJK, emoji (incl. ZWJ sequences and skin-tone modifiers),
  combining marks, RTL scripts, straight/curly quotes, backslashes, Cypher-literal
  and `$param` lookalikes (values must be BOUND, never interpolated — a value that
  would break Cypher if interpolated proves the params-only rule on the wire), JSON
  metacharacters, control bytes, the empty string, and a long mixed script string.
  Byte-exact (===) assertions — normalization or escaping bugs must red these.
  """

  use AshArcadic.Test.IntegrationCase

  require Ash.Query
  alias AshArcadic.Test.CrudPerson

  @long String.duplicate("αβγδε テスト 🎈 \"q\" \\ ", 50) <> "end"

  @corpus [
    "こんにちは世界",
    "🎉🚀 👨‍👩‍👧‍👦 👩🏽‍🚀 🏳️‍🌈",
    "café naïve — über",
    "«Großändler» sagt: \"Guten Tag\"",
    "back\\slash \\\\ doubled",
    "'single' \"$props\" `tick` ?-\"x\"",
    "line1\nline2\ttabbed\rcr",
    "JSON {\"k\": [1,2]} — nbsp   end",
    "עברית וערבית العربية",
    @long
  ]

  describe "string values round-trip byte-exact through the live engine" do
    for {value, idx} <- Enum.with_index(@corpus) do
      test "corpus[#{idx}] (#{String.slice(value, 0, 12)}…) create → read back" do
        value = unquote(value)
        id = "u#{unquote(idx)}"

        {:ok, _} =
          CrudPerson
          |> Ash.Changeset.for_create(:create, %{id: id, name: value})
          |> Ash.create()

        {:ok, [reloaded]} = CrudPerson |> Ash.Query.filter(id == ^id) |> Ash.read()
        assert reloaded.name === value
      end
    end
  end

  describe "the read path binds unicode values as params" do
    # Distinct from every @corpus value: ExUnit randomizes test order within the module,
    # so this may run before OR after the corpus tests — sharing a value with corpus[0]
    # made the single-row assertion order-dependent (caught by CI's 1.18 lane).
    test "filter name == <unicode> finds exactly that row" do
      {:ok, _} =
        CrudPerson
        |> Ash.Changeset.for_create(:create, %{id: "uf1", name: "フィルター検索テスト"})
        |> Ash.create()

      {:ok, _} =
        CrudPerson
        |> Ash.Changeset.for_create(:create, %{id: "uf2", name: "«фильтр-поиск» — otro valor"})
        |> Ash.create()

      {:ok, [hit]} = CrudPerson |> Ash.Query.filter(name == "フィルター検索テスト") |> Ash.read()
      assert hit.id == "uf1"
    end
  end

  # NOT a wire-loss bug: Ash core's :string casting applies these BEFORE the data layer
  # sees the value (deps ash type/string.ex: "By default, values are trimmed and empty
  # values are set to nil" — `trim?`/`allow_empty?` opt out). Asserted here so the
  # boundary is documented: the data layer stores EXACTLY what casting produced — the
  # trim/empty-to-nil happens at the Ash layer, never on the ArcadeDB wire.
  describe "Ash casting semantics at the boundary (not wire loss)" do
    test "an empty string becomes nil at casting (no allow_empty?) and stays nil on the wire" do
      {:ok, p} =
        CrudPerson
        |> Ash.Changeset.for_create(:create, %{id: "ub1", name: ""})
        |> Ash.create()

      assert is_nil(p.name)

      {:ok, [reloaded]} = CrudPerson |> Ash.Query.filter(id == "ub1") |> Ash.read()
      assert is_nil(reloaded.name)
    end

    test "trailing/leading whitespace is trimmed at casting; the trimmed value is stored byte-exact" do
      value = "  こんにちは trailing  "

      {:ok, _} =
        CrudPerson
        |> Ash.Changeset.for_create(:create, %{id: "ub2", name: value})
        |> Ash.create()

      {:ok, [reloaded]} = CrudPerson |> Ash.Query.filter(id == "ub2") |> Ash.read()
      assert reloaded.name === String.trim(value)
    end
  end
end
