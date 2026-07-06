defmodule AshArcadic.DataLayer.AggregateDestTypesTest do
  @moduledoc """
  Regression: a traversal aggregate folds DESTINATION records (Traverse Read B), so the storage-type
  map that drives `guard_field/2` (binary/sensitive rejection) and the `min`/`max` comparator MUST
  come from the aggregate's DESTINATION resource — not the SOURCE being read. For a self-referential
  traverse (the shipped norm) source == destination and this is moot; for a CROSS-RESOURCE traverse a
  source-typed map omits the dest-only field (guard wrongly rejects a legitimate aggregate) or
  mis-types a same-named field (wrong comparator → silent wrong min/max; a binary dest field typed as
  String on the source bypasses the sensitive guard entirely). See closeout correctness + cross-vendor.
  """
  use ExUnit.Case, async: true

  # SOURCE has :name (string) only and a manual Traverse :items to DEST. DEST has :amount (integer),
  # :measured_at (utc_datetime), and :secret (binary/sensitive) — none present on SOURCE.
  defmodule AggCrossDest do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
      label(:AggCrossDest)
      sensitive([:secret])
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :amount, :integer, public?: true
      attribute :measured_at, :utc_datetime, public?: true
      attribute :secret, :binary, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule AggCrossSource do
    @moduledoc false
    use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

    arcade do
      client(AshArcadic.Test.MockClient)
      label(:AggCrossSource)
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    relationships do
      has_many :items, AggCrossDest do
        manual(
          {AshArcadic.ManualRelationships.Traverse,
           edge_label: :HAS_ITEM, direction: :outgoing, min_depth: 1, max_depth: 1}
        )
      end
    end

    actions do
      defaults [:read]
    end
  end

  defp agg(kind, field) do
    %Ash.Query.Aggregate{
      kind: kind,
      field: field,
      relationship_path: [:items],
      name: :"#{field}_agg",
      query: nil
    }
  end

  test "aggregate_dest_types resolves the type map from the DESTINATION resource, not the source" do
    types = AshArcadic.DataLayer.aggregate_dest_types(AggCrossSource, agg(:sum, :amount))

    # DEST-only fields present, with their DESTINATION storage types (a source-typed map omits them).
    assert {Ash.Type.Integer, _} = Map.get(types, :amount)
    assert {Ash.Type.UtcDatetime, _} = Map.get(types, :measured_at)
    # The sensitive :binary dest field is typed as :binary here — so guard_field can reject a
    # value-reading aggregate over it (a source-typed map would type it wrong / omit it → bypass).
    assert {Ash.Type.Binary, _} = Map.get(types, :secret)
    # The SOURCE-only field is ABSENT — proving these are DEST types, not a leaked SOURCE map.
    refute Map.has_key?(types, :name)
  end
end
