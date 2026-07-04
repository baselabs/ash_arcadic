defmodule AshArcadic.ErrorsTest do
  use ExUnit.Case, async: true
  alias AshArcadic.Errors.{CreateFailed, QueryFailed, UnsupportedFilter, UpdateFailed}

  test "CreateFailed/QueryFailed/UpdateFailed carry resource + structural reason" do
    assert Exception.message(CreateFailed.exception(resource: Foo, reason: "boom")) =~
             "Create failed"

    assert Exception.message(QueryFailed.exception(query: "read", reason: "boom")) =~
             "Query failed"

    assert Exception.message(UpdateFailed.exception(resource: Foo, reason: "boom")) =~
             "Update failed"
  end

  test "UnsupportedFilter carries only operator + field, never a value" do
    msg =
      Exception.message(
        UnsupportedFilter.exception(operator: Ash.Query.Operator.Eq, field: :email)
      )

    assert msg =~ "Unsupported filter operator"
    assert msg =~ ":email"
  end

  test "UnsupportedFilter field: nil clause omits the field phrase" do
    msg =
      Exception.message(UnsupportedFilter.exception(operator: Ash.Query.Operator.Eq, field: nil))

    assert msg =~ "Unsupported filter operator"
    # nil clause must NOT include the field phrase
    refute msg =~ "on field"
  end

  test "UnsupportedFilter structurally carries no value/reason field (Rule 4 tripwire)" do
    err = UnsupportedFilter.exception(operator: Ash.Query.Operator.Eq, field: :email)

    refute Map.has_key?(err, :value)
    refute Map.has_key?(err, :reason)
  end
end
