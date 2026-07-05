defmodule AshArcadic.DataLayer.EncodeGateTest do
  use ExUnit.Case, async: true

  alias AshArcadic.DataLayer, as: DL
  alias AshArcadic.Errors.CreateFailed
  alias AshArcadic.Errors.UpdateFailed
  alias AshArcadic.Test.EncodeDoc

  # A raw non-UTF8 binary nested in a :map value. serialize_value/2 leaves it
  # verbatim (only TOP-LEVEL binaries are base64'd), so it reaches the JSON encoder
  # at the wire. Without the pre-gate, Arcadic.command → Req :json → Jason RAISES
  # `Jason.EncodeError` whose message embeds the bytes ("invalid byte 0xFF in
  # <<255, ...>>") — a value leak (AGENTS.md Rule 4) AND an uncaught crash crossing
  # the callback boundary instead of a value-free {:error, _}.
  @poison %{"k" => <<0xFF, 0x00, 0x42>>}

  # The sentinel byte 0xFF renders as "255" in the raised Jason message; a
  # value-free reason names only the attribute and never contains it.
  defp value_free?(reason) do
    msg = inspect(reason)
    not String.contains?(msg, "255") and not String.contains?(msg, "0xFF")
  end

  test "create fails closed value-free (no Jason raise, no bytes in the message)" do
    cs = %Ash.Changeset{resource: EncodeDoc, attributes: %{id: "e1", data: @poison}}
    assert {:error, %CreateFailed{} = err} = DL.create(EncodeDoc, cs)
    assert err.reason =~ "data"
    assert value_free?(err.reason)
  end

  test "upsert fails closed value-free on a nested non-encodable binary" do
    cs = %Ash.Changeset{resource: EncodeDoc, attributes: %{id: "e1", data: @poison}}
    assert {:error, %CreateFailed{} = err} = DL.upsert(EncodeDoc, cs, [:id])
    assert err.reason =~ "data"
    assert value_free?(err.reason)
  end

  test "update fails closed value-free on a nested non-encodable binary" do
    cs = %Ash.Changeset{
      resource: EncodeDoc,
      data: %EncodeDoc{id: "e1"},
      attributes: %{data: @poison}
    }

    assert {:error, %UpdateFailed{} = err} = DL.update(EncodeDoc, cs)
    assert err.reason =~ "data"
    assert value_free?(err.reason)
  end

  test "bulk_create fails closed value-free on a nested non-encodable binary" do
    cs = %Ash.Changeset{resource: EncodeDoc, attributes: %{id: "e1", data: @poison}}

    assert {:error, %CreateFailed{} = err} =
             DL.bulk_create(EncodeDoc, [cs], %{return_records?: true})

    assert err.reason =~ "data"
    assert value_free?(err.reason)
  end

  # Positive control: an encodable :map value must pass the gate and proceed to the
  # write path (which then fails only on MockClient's bad auth — a reason WITHOUT the
  # encode-gate string), proving the gate does not blanket-reject :map attributes.
  test "an encodable :map value passes the gate (reaches the write path)" do
    cs = %Ash.Changeset{resource: EncodeDoc, attributes: %{id: "e1", data: %{"k" => "ok"}}}
    assert {:error, %CreateFailed{} = err} = DL.create(EncodeDoc, cs)
    refute err.reason =~ "not JSON-encodable"
  end
end
