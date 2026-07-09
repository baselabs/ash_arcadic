defmodule AshArcadic.Test.CalcPerson do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:CalcPerson)
    sensitive([:secret])
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :first, :string, public?: true
    attribute :last, :string, public?: true
    attribute :a, :integer, public?: true
    attribute :b, :integer, public?: true
    attribute :secret, :binary, public?: true
  end

  calculations do
    calculate :full_name, :string, expr(first <> " " <> last), public?: true
    calculate :total, :integer, expr(a + b), public?: true
    calculate :ratio, :float, expr(a / b), public?: true
    calculate :greeting, :string, {AshArcadic.Test.CalcGreeting, []}, public?: true
    calculate :secret_calc, :string, expr(secret <> "!"), public?: true
  end

  actions do
    default_accept [:id, :org_id, :first, :last, :a, :b, :secret]
    defaults [:read, :create, :update, :destroy]
  end
end
