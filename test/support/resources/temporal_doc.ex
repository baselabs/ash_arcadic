defmodule AshArcadic.Test.TemporalDoc do
  @moduledoc """
  Slice 11 temporal-comparison test resource. ArcadeDB auto-coerces stored ISO8601 datetime/time
  strings to its native temporal types, so `prop OP $stringparam` silently returns wrong results —
  the fix wraps the bound param in the type's Cypher temporal constructor (`datetime()`/`localtime()`).
  `:date` is NOT coerced (kept a string) so it needs no wrapper. This resource carries one attribute
  per temporal storage class so the fix is validated per type (utc_datetime / naive_datetime / time
  wrapped; date plain).
  """
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:TemporalDoc)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :at, :utc_datetime, public?: true
    attribute :naive_at, :naive_datetime, public?: true
    attribute :on_date, :date, public?: true
    attribute :at_time, :time, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept [:id, :org_id, :at, :naive_at, :on_date, :at_time]
    defaults [:read, :create]
  end
end
