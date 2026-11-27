defmodule AshArcadic.Test.StoredType do
  @moduledoc false

  use Ash.Type.NewType, subtype_of: :string

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored("stored:" <> value, _constraints), do: {:ok, String.upcase(value)}
  def cast_stored(value, _constraints), do: {:error, message: value}
end

defmodule AshArcadic.Test.Visibility do
  @moduledoc false

  use Ash.Type.Enum, values: [:public, :internal]
end
