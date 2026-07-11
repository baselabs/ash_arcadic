defmodule AshArcadic.Test.AtomicCounter do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:AtomicCounter)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :count, :integer, public?: true
    attribute :label_txt, :string, public?: true
  end

  actions do
    default_accept [:id, :count, :label_txt]
    defaults [:read, :create, :update, :destroy]

    create :create_with_bump do
      accept [:id]
      change atomic_set(:count, expr(100 + 1))
    end

    # PK-based upsert (no named identity — matches the UpsertThing pattern); the
    # atomic_update lands in changeset.atomics, applied ON MATCH only.
    create :upsert_bump do
      accept [:id]
      upsert? true
      change atomic_update(:count, expr(count + 5))
    end

    # Routes a caller-supplied raw binary into an atomic create RHS (create_atomics)
    # for the poisoned-non-UTF8 encode-gate regression test. The concat keeps the RHS a
    # genuine EXPRESSION: cast_atomic statically casts a bare `^arg(:bad)` literal into
    # changeset.attributes (props path), never create_atomics — verified empirically.
    create :poison_name do
      accept [:id]
      argument :bad, :string
      change atomic_set(:label_txt, expr(^arg(:bad) <> "sfx"))
    end
  end
end
