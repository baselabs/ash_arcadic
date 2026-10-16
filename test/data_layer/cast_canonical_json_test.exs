defmodule AshArcadic.DataLayer.CastCanonicalJsonTest do
  @moduledoc false
  # Unit pins for the canonical-JSON :map representation (the 26.10 openCypher
  # property-value adaptation) — the delta-review repair round's red tests:
  # struct leaves (a Jason-encodable struct such as Ash.CiString must encode,
  # value-free, NOT raise; an encoder-less struct soft-fails for the gates) and
  # numeric keys (Jason accepts them, so the canonical form must too — a soft
  # miss would pass the raw map through the encode gate to a wire that rejects
  # map properties).
  use ExUnit.Case, async: true

  alias AshArcadic.Cast

  defmodule NoEncoderStruct do
    @moduledoc false
    defstruct [:field]
  end

  @map_spec {Ash.Type.Map, []}

  defp serialize(value), do: Cast.serialize_value(value, @map_spec)

  test "equal maps with differently-ordered keys encode identically (the equality law)" do
    a = %{"z" => 1, "a" => %{"y" => true, "b" => [1, 2]}}
    b = %{"a" => %{"b" => [1, 2], "y" => true}, "z" => 1}
    assert serialize(a) == serialize(b)
    assert is_binary(serialize(a))
  end

  test "a Jason-encodable struct leaf (Ash.CiString) encodes value-free, never raises" do
    # Before the repair, a struct hit the is_map clause and Enum raised
    # (Protocol.UndefinedError echoing the struct — a Rule-4 leak AND a broken
    # valid write; delta-review D1).
    json = serialize(%{"name" => Ash.CiString.new("CaNaRy")})
    assert is_binary(json)
    assert json =~ "name"
  end

  test "an encoder-less struct soft-fails to the ORIGINAL value (the gates reject it)" do
    original = %{"k" => %NoEncoderStruct{field: "CANARY"}}
    assert serialize(original) == original
  end

  test "numeric keys encode canonically (Jason accepts them; so must we)" do
    # Before the repair, canonical_key/1 soft-failed on integer keys, the raw
    # map slipped past the encode gate (Jason encodes it too), and a map
    # property reached a 26.10 wire that rejects it (delta-review D4).
    json = serialize(%{1 => "x", "a" => 2})
    assert is_binary(json)
    assert json == ~S({"1":"x","a":2})
  end

  test "round-trip: serialize then load returns the map" do
    value = %{"b" => 2, "a" => 1, "nested" => %{"k" => [1, 2.5, nil, true]}}
    assert Cast.load_value(serialize(value), @map_spec) == value
  end

  test "legacy embedded rows (a returned MAP) load unchanged" do
    legacy = %{"k" => "v"}
    assert Cast.load_value(legacy, @map_spec) == legacy
  end

  test "an {:array, :map} serializes element-wise and loads back" do
    spec = {{:array, Ash.Type.Map}, []}
    value = [%{"a" => 1}, nil, %{"b" => [2]}]
    encoded = Cast.serialize_value(value, spec)
    assert encoded == ["{\"a\":1}", nil, "{\"b\":[2]}"]
    assert Cast.load_value(encoded, spec) == value
  end
end
