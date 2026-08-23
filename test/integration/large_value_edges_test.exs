defmodule AshArcadic.Integration.LargeValueEdgesTest do
  @moduledoc """
  Large-value edges against the live wire (R7): multi-MB strings, multi-MB
  binary-storage attributes (base64 on the wire), and deeply-nested `:map`
  values — driven through Ash actions, not the raw transport.

  Boundaries LIVE-PROBED on the pinned image (26.8.1, this slice — direct
  transport probes preceded these tests):

  - Multi-MB strings round-trip byte-exact through the wire (probed at
    1/4/16 MB; the tests pin 4 MB to keep the suite fast).
  - A 3 MB `:binary` attribute (base64-encoded by `Cast.serialize_value/2`,
    ~4 MB on the wire) round-trips DECODED — the read path's `decode_binary/1`
    returns the original bytes.
  - `:map` parameter NESTING is capped at 32 levels SERVER-SIDE (HTTP 400
    `IllegalArgumentException`, detail "Parameter nesting exceeds 32 levels -
    typed-marker decoder refuses to recurse further"). The data layer's wire
    shape spends 2 of them (the `$props` envelope + the attribute key), so a
    `:map` ATTRIBUTE accepts at most 30 nesting levels through an Ash action:
    depth 30 round-trips (probed: bare params accept 31, envelope-wrapped 30),
    depth 31 is rejected. The rejection is a clean 400 (`:server_error` class
    in arcadic's taxonomy — the FQN maps nowhere) — this test pins that it
    surfaces through the Ash boundary value-free.

  The depth-32 write is retried by the client write-retry loop (`:server_error`
  is a retriable class) — bounded at 5 attempts, then the redacted error.
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
  @nest_depth_ok 30
  @nest_depth_over 31

  defp nest(depth),
    do: Enum.reduce(1..depth, %{"leaf" => @leaf_sentinel}, fn _, acc -> %{"n" => acc} end)

  defp create_doc!(attrs) do
    LargeValueDoc
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  describe "multi-MB string values" do
    test "a 4 MB string round-trips byte-exact through Ash create + read" do
      blob = "SNT_head_x1" <> String.duplicate("y", 4_000_000) <> "SNT_tail_x9"

      doc = create_doc!(%{tag: "big", blob: blob})
      assert byte_size(doc.blob) == byte_size(blob)

      read_back = Ash.read_one!(Ash.Query.filter(LargeValueDoc, tag == "big"))
      assert read_back.blob == blob
    end
  end

  describe "multi-MB binary-storage attributes" do
    test "a 3 MB binary round-trips as the ORIGINAL bytes (base64 wire form decoded on read)" do
      bytes = :crypto.strong_rand_bytes(3_000_000)

      doc = create_doc!(%{tag: "bin", payload: bytes})
      assert byte_size(doc.payload) == byte_size(bytes)

      read_back = Ash.read_one!(Ash.Query.filter(LargeValueDoc, tag == "bin"))
      # Byte-equality, not base64-equality: the read path must have decoded.
      assert read_back.payload == bytes
    end
  end

  describe "deeply-nested :map values" do
    test "depth 30 (the accepted maximum through the $props envelope) round-trips shape-preserved" do
      create_doc!(%{tag: "deep30", data: nest(@nest_depth_ok)})

      read_back = Ash.read_one!(Ash.Query.filter(LargeValueDoc, tag: "deep30"))

      # Structural equality — every level, the leaf sentinel, string keys, all of it.
      # (ArcadeDB returns JSON-decoded string-keyed maps, exactly the shape nest/1 builds.)
      assert read_back.data == nest(@nest_depth_ok)
    end

    test "depth 31 is rejected value-free — the server's nesting cap surfaces as a redacted error" do
      assert {:error, error} =
               LargeValueDoc
               |> Ash.Changeset.for_create(:create, %{tag: "deep31", data: nest(@nest_depth_over)})
               |> Ash.create()

      assert Enum.any?(error.errors, &match?(%AshArcadic.Errors.CreateFailed{}, &1)),
             "expected the failure to surface as a CreateFailed, got: #{inspect(error.errors)}"

      # The 400's unmapped FQN → :server_error class, redacted.
      assert Exception.message(error) =~ "ArcadeDB error (server_error)"

      # Value-free: neither the sentinel leaf value nor the server's detail text rides.
      refute Exception.message(error) =~ @leaf_sentinel
      refute inspect(error) =~ @leaf_sentinel
      refute Exception.message(error) =~ "nesting exceeds"
    end
  end
end
