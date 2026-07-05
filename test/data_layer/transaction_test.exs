defmodule AshArcadic.TransactionTest do
  use ExUnit.Case, async: true

  alias AshArcadic.Transaction

  setup do
    on_exit(fn -> Transaction.clear() end)
    :ok
  end

  describe "marker + session primitives" do
    test "in_transaction? is false until begin_marker, true after, false after clear" do
      refute Transaction.in_transaction?()
      assert :ok = Transaction.begin_marker()
      assert Transaction.in_transaction?()
      assert :ok = Transaction.clear()
      refute Transaction.in_transaction?()
    end

    test "session/0 is nil until put_session, then round-trips, then nil after clear" do
      conn = %Arcadic.Conn{base_url: "u", database: "t_a", auth: {"root", "pw"}, session_id: "s1"}
      assert Transaction.session() == nil
      assert :ok = Transaction.put_session(conn)
      assert Transaction.session() == conn
      Transaction.clear()
      assert Transaction.session() == nil
    end

    test "rollback_throw/1 throws the module-specific tagged tuple" do
      caught =
        try do
          Transaction.rollback_throw(:abort)
        catch
          :throw, value -> value
        end

      assert caught == {:ash_arcadic_rollback, :abort}
    end
  end
end
