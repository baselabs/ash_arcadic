defmodule AshArcadic.Errors.UpdateFailed do
  @moduledoc "Error for failed update operations. Carries only resource + structural reason."
  use Splode.Error, fields: [:resource, :reason], class: :invalid

  def message(%{resource: resource, reason: reason}),
    do: "Update failed for #{inspect(resource)}: #{inspect(reason)}"
end
