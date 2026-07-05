defmodule AshArcadic.Test.TraverseAttrNode do
  @moduledoc false
  use Ash.Resource, domain: AshArcadic.Test.Domain, data_layer: AshArcadic.DataLayer

  arcade do
    client(AshArcadic.Test.IntegrationClient)
    label(:TravAttrNode)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :name, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  relationships do
    has_many :descendants, __MODULE__ do
      manual(
        {AshArcadic.ManualRelationships.Traverse,
         edge_label: :PARENT_OF, direction: :outgoing, min_depth: 1, max_depth: 3}
      )
    end

    # :both (undirected) — proves the native ALL(nodes(p)) predicate scopes every node
    # regardless of edge direction (closeout probe-confirmed; integration-gated below).
    has_many :connected, __MODULE__ do
      manual(
        {AshArcadic.ManualRelationships.Traverse,
         edge_label: :PARENT_OF, direction: :both, min_depth: 1, max_depth: 3}
      )
    end

    # scope_edges: false — the documented opt-out: node scoping still applies, but edges
    # are NOT scoped (for graphs whose edges are written out-of-band without the stamp).
    has_many :descendants_unscoped_edges, __MODULE__ do
      manual(
        {AshArcadic.ManualRelationships.Traverse,
         edge_label: :PARENT_OF,
         direction: :outgoing,
         min_depth: 1,
         max_depth: 3,
         scope_edges: false}
      )
    end
  end

  actions do
    default_accept [:id, :org_id, :name]
    defaults [:read, :create, :update, :destroy]
  end
end
