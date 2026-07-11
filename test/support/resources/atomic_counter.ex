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
    attribute :dec, :decimal, public?: true
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

    # An atomic create RHS referencing a :decimal field — Expression.ref_ok? rejects
    # :decimal storage (exact-string; Cypher value ops over it are wrong, D27), so the
    # atomic fold returns {:error, %UnsupportedFilter{}}. The field-ref keeps the RHS a
    # genuine EXPRESSION (never statically cast into attributes); the ^arg routes a
    # caller value in so the value-free assertion on the normalized error is non-vacuous.
    create :bad_atomic_rhs do
      accept [:id]
      argument :secret, :integer
      change atomic_set(:count, expr(dec + ^arg(:secret)))
    end

    # PK-based upsert whose CREATE-phase atomic (atomic_set → changeset.create_atomics) must apply on
    # the INSERT branch (ON CREATE SET), NOT ON MATCH. Distinct from :upsert_bump (atomic_update →
    # changeset.atomics → ON MATCH). Proves the V8 fold covers the upsert-insert surface.
    create :upsert_create_bump do
      accept [:id]
      upsert? true
      change atomic_set(:count, expr(100 + 1))
    end

    # Upsert whose ON MATCH atomic RHS carries a caller binary (atomic_update → changeset.atomics),
    # for the encode-gate poison regression on the upsert path (mirror of :poison_name on create).
    # The field-ref concat keeps the RHS a genuine EXPRESSION so the poison rides the atomic $paramN.
    create :upsert_poison do
      accept [:id]
      argument :bad, :string
      upsert? true
      change atomic_update(:label_txt, expr(label_txt <> ^arg(:bad)))
    end
  end
end
