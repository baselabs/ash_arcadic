defmodule AshArcadic.Test.MockClient do
  @moduledoc false
  @behaviour AshArcadic.Client

  @impl true
  def conn do
    Arcadic.connect("http://127.0.0.1:41478", "ash_arcadic_test", auth: {"root", "pw"})
  end
end
