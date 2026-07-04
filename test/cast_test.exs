defmodule AshArcadic.CastTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Cast

  defmodule BinNewType do
    use Ash.Type.NewType, subtype_of: :binary
  end

  test "serialize_value ISO8601-encodes dates/datetimes; passes native JSON through" do
    assert Cast.serialize_value(~D[2026-07-04], {Ash.Type.Date, []}) == "2026-07-04"

    assert Cast.serialize_value(~U[2026-07-04 12:00:00Z], {Ash.Type.UtcDatetime, []}) ==
             "2026-07-04T12:00:00Z"

    assert Cast.serialize_value("plain", {Ash.Type.String, []}) == "plain"
    assert Cast.serialize_value(42, {Ash.Type.Integer, []}) == 42
  end

  test "binary-storage values round-trip via base64 (no tag), matchable both ways" do
    bytes = <<1, 2, 3, 255>>
    encoded = Cast.serialize_value(bytes, {Ash.Type.Binary, []})
    assert is_binary(encoded) and encoded == Base.encode64(bytes)
    assert Cast.load_value(encoded, {Ash.Type.Binary, []}) == bytes
  end

  test "binary_storage?/2 reflects Ash.Type.storage_type" do
    assert Cast.binary_storage?(Ash.Type.Binary, [])
    refute Cast.binary_storage?(Ash.Type.String, [])
  end

  test "binary_storage?/2 sees through a NewType wrapping :binary (moduledoc round-trip claim)" do
    assert Cast.binary_storage?(BinNewType, [])
  end

  test "nil spec passes binary values through untouched (no spurious base64 decode)" do
    # A valid-base64-shaped string must NOT be guess-decoded when the spec is nil.
    assert Cast.load_value("dGVzdA==", nil) == "dGVzdA=="
    assert Cast.serialize_value("dGVzdA==", nil) == "dGVzdA=="
  end

  test "naive_datetime round-trips via ISO8601" do
    ndt = ~N[2026-07-04 12:00:00]
    encoded = Cast.serialize_value(ndt, {Ash.Type.NaiveDatetime, []})
    assert encoded == NaiveDateTime.to_iso8601(ndt)
    assert Cast.load_value(encoded, {Ash.Type.NaiveDatetime, []}) == ndt
  end

  test "row_to_attrs routes strictly by attribute_map, ignoring @rid/@cat/@type and undeclared keys" do
    row = %{
      "@rid" => "#1:0",
      "@cat" => "v",
      "@type" => "Person",
      "id" => "p1",
      "born" => "2026-07-04",
      "extra" => "x"
    }

    attr_map = %{id: "id", born: "born"}
    types = %{id: {Ash.Type.String, []}, born: {Ash.Type.Date, []}}
    assert Cast.row_to_attrs(row, attr_map, types) == %{id: "p1", born: ~D[2026-07-04]}
  end
end
