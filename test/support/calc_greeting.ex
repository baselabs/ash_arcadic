defmodule AshArcadic.Test.CalcGreeting do
  @moduledoc false
  use Ash.Resource.Calculation
  @impl true
  def load(_query, _opts, _context), do: [:first]
  @impl true
  def calculate(records, _opts, _context), do: Enum.map(records, &("Hi " <> (&1.first || "")))
end
