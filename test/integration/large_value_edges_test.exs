defmodule AshArcadic.Integration.LargeValueEdgesTest do
  @moduledoc """
  Large-value edges against the live wire (R7): multi-MB strings, multi-MB
  binary-storage attributes (base64 on the wire), and deeply-nested `:map`
  values — driven through Ash actions, not the raw transport.

  Boundaries LIVE-PROBED on the pinned images (26.8.1 then 26.10.2):

  - Multi-MB strings round-trip byte-exact through the wire (probed at
    1/4/16 MB; the tests pin 4 MB to keep the suite fast).
  - A 3 MB `:binary` attribute (base64-encoded by `Cast.serialize_value/2`,
    ~4 MB on the wire) round-trips DECODED — the read path's `decode_binary/1`
    returns the original bytes.
  - `:map` attributes ride the wire as a CANONICAL JSON STRING since the
    26.10 adaptation: ArcadeDB's 26.10 line enforces the openCypher
    property-value rule (primitives or arrays of primitives only — a map
    property write is rejected 400 `InvalidPropertyTypeException`; live-probed
    26.8.1 vs 26.10.2), and a JSON string is a legal property value on every
    supported server. The ≤26.9 servers' 32-level parameter-nesting cap no
    longer applies to a string property, so arbitrarily deep maps round-trip
    (pinned at 30 and 60 levels); rows written as embedded documents by
    ash_arcadic <= 1.1 still read back (the decode accepts both shapes).
  """

  use AshArcadic.Test.IntegrationCase

  require Ash.Query

  defmodule LargeValueDoc do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.IntegrationClient)
      label(:LargeValueDoc)
    end

    attributes do
      uuid_primary_key :id
      attribute :tag, :string, public?: true
      attribute :blob, :string, public?: true
      attribute :payload, :binary, public?: true
      attribute :data, :map, public?: true
    end

    actions do
      default_accept [:tag, :blob, :payload, :data]
      defaults [:read, :create]
    end
  end

  @leaf_sentinel "SNT_leaf_x1"
  @nest_depth 30
  @nest_depth_deep 60

  defp nest(depth),
    do: Enum.reduce(1..depth, %{"leaf" => @leaf_sentinel}, fn _, acc -> %{"n" => acc} end)

  defp create_doc!(attrs) do
    LargeValueDoc
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  defp read_tagged!(tag) do
    Ash.read_one!(Ash.Query.filter(LargeValueDoc, tag == ^tag))
  end

  describe "multi-MB string values" do
    test "a 4 MB string round-trips byte-exact through Ash create + read" do
      blob = "SNT_head_x1" <> String.duplicate("y", 4_000_000) <> "SNT_tail_x9"

      doc = create_doc!(%{tag: "big", blob: blob})
      assert byte_size(doc.blob) == byte_size(blob)

      read_back = read_tagged!("big")
      assert read_back.blob == blob
    end
  end

  describe "multi-MB binary-storage attributes" do
    test "a 3 MB binary round-trips as the ORIGINAL bytes (base64 wire form decoded on read)" do
      bytes = :crypto.strong_rand_bytes(3_000_000)

      doc = create_doc!(%{tag: "bin", payload: bytes})
      assert byte_size(doc.payload) == byte_size(bytes)

      read_back = read_tagged!("bin")
      # Byte-equality, not base64-equality: the read path must have decoded.
      assert read_back.payload == bytes
    end
  end

  describe "deeply-nested :map values (canonical JSON string representation)" do
    test "depth 30 round-trips shape-preserved" do
      create_doc!(%{tag: "deep30", data: nest(@nest_depth)})

      read_back = read_tagged!("deep30")

      # Structural equality — every level, the leaf sentinel, string keys, all of it.
      # (The JSON-string representation decodes back to string-keyed maps, exactly the
      # shape nest/1 builds.)
      assert read_back.data == nest(@nest_depth)
    end

    # The <=26.9 server nesting cap (32 levels) does not apply to the string representation —
    # depth 60 round-trips on the same server that rejected depth 31 as a raw map param.
    test "depth 60 round-trips shape-preserved (the <=26.9 nesting cap is lifted)" do
      create_doc!(%{tag: "deep60", data: nest(@nest_depth_deep)})

      read_back = read_tagged!("deep60")
      assert read_back.data == nest(@nest_depth_deep)
    end

    test "a map value round-trips through an EQUALITY filter on the map attribute" do
      # The canonical encoding makes the stored string deterministic, so an equality filter
      # (which serializes its operand through the same canonical encoder) matches.
      value = %{"b" => 2, "a" => 1, "nested" => %{"z" => true, "k" => [1, 2, 3]}}
      create_doc!(%{tag: "mapkey", data: value})

      read_back = Ash.read_one!(Ash.Query.filter(LargeValueDoc, data == ^value))
      assert read_back.tag == "mapkey"
      assert read_back.data == value
    end
  end
end
