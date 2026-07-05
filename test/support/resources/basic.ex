defmodule AshArcadic.Test.Basic do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.MockClient)
    label(:Person)
    sensitive([:secret])
    skip([:computed])
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :secret, :binary, public?: true
    attribute :computed, :string, public?: false
    attribute :age, :integer, public?: true
    attribute :amount, :decimal, public?: true
  end

  actions do
    # Read-only: the Task 6 skeleton advertises only `:multitenancy` in `can?/2`
    # (create/update/destroy land in Plans 2-4). Ash's ValidateActionTypesSupported
    # verifier raises for any create/update/destroy action whose type `can?/2`
    # does not support, which `--warnings-as-errors` promotes to a hard failure.
    # `:read` and `:action` types are exempt from that verifier, so a read-only
    # fixture compiles clean and still exercises every assertion this task makes.
    defaults [:read]
  end
end
