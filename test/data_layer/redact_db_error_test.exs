defmodule AshArcadic.DataLayer.RedactDbErrorTest do
  use ExUnit.Case, async: true

  test "an Arcadic.Error is redacted to its typed reason only — never detail/message" do
    err = %Arcadic.Error{
      reason: :duplicate_key,
      http_status: 409,
      exception: "DuplicatedKeyException",
      message: "Key (email)=(secret@user.com) already exists",
      detail: "MATCH (n) WHERE n.email = 'secret@user.com'"
    }

    reason = AshArcadic.DataLayer.redact_db_error(err)
    assert reason =~ "duplicate_key"
    refute reason =~ "secret@user.com"
    refute reason =~ "email"
  end

  test "an Arcadic.TransportError is redacted to its reason atom" do
    reason = AshArcadic.DataLayer.redact_db_error(%Arcadic.TransportError{reason: :closed})
    assert reason =~ "closed"
  end

  test "any other term is redacted to a static value-free reason (never inspected)" do
    reason = AshArcadic.DataLayer.redact_db_error({:leak, "secret@user.com"})
    assert is_binary(reason)
    refute reason =~ "secret@user.com"
  end

  # A TransportError.reason is NOT guaranteed to be an atom: arcadic passes the
  # underlying Req/Mint reason through verbatim (../arcadic transport/http.ex:85,153,
  # 197,209,239; bolt/connection.ex:20), and Mint's reason type is term() — tuples,
  # charlists, and strings all reach here and can embed a host/value. The guard must
  # fail these CLOSED to the static catch-all, never interpolate them.
  test "a non-atom TransportError tuple reason fails closed — never raises, never leaks the value" do
    result =
      AshArcadic.DataLayer.redact_db_error(%Arcadic.TransportError{
        reason: {:bad_alpn_protocol, "db.internal"}
      })

    assert result == "ArcadeDB error"
    refute result =~ "db.internal"
  end

  test "a charlist TransportError reason fails closed — never leaks the host substring" do
    result =
      AshArcadic.DataLayer.redact_db_error(%Arcadic.TransportError{
        reason: ~c"connect timeout to db.internal:2480"
      })

    assert result == "ArcadeDB error"
    refute result =~ "db.internal"
  end

  test "a string TransportError reason fails closed — never leaks the host substring" do
    result =
      AshArcadic.DataLayer.redact_db_error(%Arcadic.TransportError{
        reason: "db.internal:2480 refused"
      })

    assert result == "ArcadeDB error"
    refute result =~ "db.internal"
  end
end
