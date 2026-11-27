defmodule AshArcadic.Errors.TransactionConflict do
  @moduledoc """
  An ArcadeDB MVCC conflict. Retry the entire Ash transaction with a fresh read.
  """

  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "ArcadeDB transaction conflict. Retry the entire transaction."
end
