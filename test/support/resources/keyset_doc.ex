defmodule AshArcadic.Test.KeysetDoc do
  @moduledoc """
  Slice 11 keyset-pagination test resource (:attribute tenancy). Its read action advertises
  `keyset?: true` (+ offset/count) so `Ash.read(page: [after: cursor, limit: n])` and `Ash.stream!`
  exercise the keyset path. Carries one attribute per admitted stored sortable type so the multi-type
  correctness suite (Task 3) can walk a keyset over each: `:score` (integer, Task 2 core), `:title`
  (string collation), `:rank` (float), `:active` (boolean), `:created` (utc_datetime); plus the two
  FAIL-CLOSED sort fields — `:blob` (:binary → sort gate `UnsortableField`) and `:amount` (:decimal →
  `UnsortableField`). Duplicate values across rows are seeded by the tests so the pk tiebreaker is exercised.
  """
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:KeysetDoc)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :score, :integer, public?: true
    attribute :title, :string, public?: true
    attribute :rank, :float, public?: true
    attribute :active, :boolean, public?: true
    attribute :created, :utc_datetime, public?: true
    # Fail-closed sort types (Task 3): base64 binary is not byte-order-preserving; :decimal is an
    # exact lexicographic string — both rejected at the SORT gate (can?({:sort, :binary/:decimal})).
    attribute :blob, :binary, public?: true
    attribute :amount, :decimal, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  calculations do
    # A NON-STORED expression calc — sorting a keyset by it makes Ash build a cursor filter over a
    # computed (unstored) Ref, which the S6 filter guard rejects (Task 3 fail-closed path 2).
    calculate :bumped_score, :integer, expr(score + 1)
  end

  actions do
    default_accept [:id, :org_id, :score, :title, :rank, :active, :created, :blob, :amount]
    defaults [:create]

    read :read do
      primary? true

      # keyset? enables the cursor path; offset?/countable keep offset + page:[count:true] available.
      # required?: false so a plain no-page read still returns a list.
      pagination keyset?: true, offset?: true, countable: true, required?: false
    end
  end
end
