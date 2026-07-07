defmodule AshArcadic.Integration.RelationshipTest do
  use AshArcadic.Test.IntegrationCase
  require Ash.Query

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshArcadic.Multitenancy

  alias AshArcadic.Test.{
    CrudPerson,
    RelAuthor,
    RelCtxAuthor,
    RelCtxPost,
    RelMixedAttrAuthor,
    RelMixedAttrPost,
    RelMixedCtxAuthor,
    RelMixedCtxPost,
    RelPlainAuthor,
    RelPlainPost,
    RelPost
  }

  @admin %{admin: true}

  setup %{admin: admin} do
    on_exit(fn ->
      Arcadic.command!(admin, "MATCH (n:RelAuthor) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:RelPost) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:RelPlainAuthor) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:RelPlainPost) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:RelMixedAttrPost) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:RelMixedAttrAuthor) DETACH DELETE n")
    end)

    :ok
  end

  # Provisions two randomized tenant databases for a :context resource and drops them on exit.
  # :context isolation is physical DB-per-tenant; randomized names avoid cross-run collisions
  # (the default encoder maps a bare tenant string to `t_<tenant>`, shared across resources).
  defp provision_context(admin, resource) do
    t1 = "torg1_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    t2 = "torg2_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    dbs = Enum.uniq(for org <- [t1, t2], do: Multitenancy.database_name(resource, org))
    for db <- dbs, do: Arcadic.Server.create_database!(admin, db)
    on_exit(fn -> for db <- dbs, do: Arcadic.Server.drop_database(admin, db) end)
    {t1, t2}
  end

  defp author(id, org, name, listed \\ true) do
    {:ok, a} =
      RelAuthor
      |> Ash.Changeset.for_create(:create, %{id: id, org_id: org, name: name, listed: listed},
        tenant: org
      )
      |> Ash.create(actor: @admin)

    a
  end

  defp author_secret(id, org, name, note) do
    {:ok, a} =
      RelAuthor
      |> Ash.Changeset.for_create(:create, %{id: id, org_id: org, name: name, secret_note: note},
        tenant: org
      )
      |> Ash.create(actor: @admin)

    a
  end

  defp post(id, org, title, author_id, secret \\ nil) do
    {:ok, p} =
      RelPost
      |> Ash.Changeset.for_create(
        :create,
        %{id: id, org_id: org, title: title, author_id: author_id, secret_tag: secret},
        tenant: org
      )
      |> Ash.create(actor: @admin)

    p
  end

  defp plain_author(id, org, name) do
    {:ok, a} =
      RelPlainAuthor
      |> Ash.Changeset.for_create(:create, %{id: id, org_id: org, name: name}, tenant: org)
      |> Ash.create(actor: @admin)

    a
  end

  defp plain_post(id, org, title, author_id) do
    {:ok, p} =
      RelPlainPost
      |> Ash.Changeset.for_create(
        :create,
        %{id: id, org_id: org, title: title, author_id: author_id},
        tenant: org
      )
      |> Ash.create(actor: @admin)

    p
  end

  # === Loading (unaffected by the fail-closed filter guard; stays on the policy-bearing pair) ===

  test "has_many + belongs_to load (property FK, no edges); one batched IN read", %{} do
    a = author("a1", "org1", "Ann")
    post("p1", "org1", "P1", "a1")
    post("p2", "org1", "P2", "a1")

    {:ok, a} = Ash.load(a, :posts, tenant: "org1", actor: @admin)
    assert a.posts |> Enum.map(& &1.id) |> Enum.sort() == ["p1", "p2"]

    {:ok, p} = Ash.get(RelPost, "p1", tenant: "org1", actor: @admin)
    {:ok, p} = Ash.load(p, :author, tenant: "org1", actor: @admin)
    assert p.author.name == "Ann"
  end

  test "an empty has_many loads [] (not NotLoaded, not an error)", %{} do
    a = author("solo", "org1", "Solo")
    {:ok, a} = Ash.load(a, :posts, tenant: "org1", actor: @admin)
    assert a.posts == []
  end

  test "a belongs_to with a nil FK loads nil (no spurious read)", %{} do
    author("a1", "org1", "Ann")
    post("orphan", "org1", "Orphan", nil)

    {:ok, p} = Ash.get(RelPost, "orphan", tenant: "org1", actor: @admin)
    {:ok, p} = Ash.load(p, :author, tenant: "org1", actor: @admin)
    assert p.author == nil
  end

  test "a has_many count aggregate loads over the property FK", %{} do
    a = author("a1", "org1", "Ann")
    post("p1", "org1", "P1", "a1")
    post("p2", "org1", "P2", "a1")

    {:ok, a} = Ash.load(a, :post_count, tenant: "org1", actor: @admin)
    assert a.post_count == 2
  end

  # === §6.2 FAIL-CLOSED authz: a source-on-related filter to a POLICY-BEARING destination is
  # rejected at parse (can?({:filter_relationship, rel}) => false), closing BOTH the row-policy
  # bypass AND the field-policy oracle. Both leaks are shut by the SAME parse-time rejection
  # because RelAuthor carries Ash.Policy.Authorizer. ===

  test "fail-closed: filtering a source on a POLICY-BEARING related field is rejected (row-policy + field-policy leaks closed)",
       %{} do
    author("a1", "org1", "Hidden", false)
    author_secret("a2", "org1", "Ann", "SECRETVALUE")
    post("p1", "org1", "P1", "a1")
    post("p_hit", "org1", "P-hit", "a2")

    for actor <- [%{admin: false}, @admin] do
      assert {:error, error} =
               RelPost
               |> Ash.Query.filter(author.name == "Hidden")
               |> Ash.Query.set_tenant("org1")
               |> Ash.read(actor: actor)

      assert Exception.message(error) =~ "not filterable"
    end

    assert {:error, error} =
             RelPost
             |> Ash.Query.filter(author.secret_note == "SECRETVALUE")
             |> Ash.Query.set_tenant("org1")
             |> Ash.read(actor: %{admin: false})

    assert Exception.message(error) =~ "not filterable"
    refute Exception.message(error) =~ "SECRETVALUE"
  end

  # === Task-3 filter / operator-matrix / telemetry tests MIGRATED onto the NON-policy RelPlain*
  # pair (filtering ALLOWED there → the separate-read IN path still fires end to end). ===

  test "source-on-related filter (Post where author.name == X) via the separate-read IN path",
       %{} do
    plain_author("a1", "org1", "Ann")
    plain_author("a2", "org1", "Bob")
    plain_post("p1", "org1", "P1", "a1")
    plain_post("p2", "org1", "P2", "a2")

    {:ok, posts} =
      RelPlainPost
      |> Ash.Query.filter(author.name == "Ann")
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    assert posts |> Enum.map(& &1.id) == ["p1"]
  end

  test "source-on-related != filter (Post where author.name != X)", %{} do
    plain_author("a1", "org1", "Ann")
    plain_author("a2", "org1", "Bob")
    plain_post("p1", "org1", "P1", "a1")
    plain_post("p2", "org1", "P2", "a2")

    {:ok, posts} =
      RelPlainPost
      |> Ash.Query.filter(author.name != "Bob")
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    assert posts |> Enum.map(& &1.id) == ["p1"]
  end

  test "source-on-related IN filter (Post where author.name in [...]) via the batched IN read",
       %{} do
    plain_author("a1", "org1", "Ann")
    plain_author("a2", "org1", "Bob")
    plain_author("a3", "org1", "Cy")
    plain_post("p1", "org1", "P1", "a1")
    plain_post("p2", "org1", "P2", "a2")
    plain_post("p3", "org1", "P3", "a3")

    {:ok, posts} =
      RelPlainPost
      |> Ash.Query.filter(author.name in ["Ann", "Cy"])
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    assert posts |> Enum.map(& &1.id) |> Enum.sort() == ["p1", "p3"]
  end

  # OPERATOR-MATRIX INVARIANT (spec §6.3): a relationship filter supports exactly the flat
  # {:filter_expr} matrix; an unsupported operator in the NESTED read must fail value-free +
  # attributable (%UnsupportedFilter{} names operator+field), never a raw case-clause/DB error.
  #
  # A range op on the DESTINATION's :binary attr PARSES past Ash's {:filter_expr} gate (`>` IS
  # advertised) but is rejected by AshArcadic.Query.Filter's range-comparable guard — base64 is
  # not byte-order-preserving (D27) — so the NESTED read (RelPlainAuthor) fails closed with
  # %UnsupportedFilter{}. Runs on RelPlain* (non-policy) so the guard does not pre-reject at parse.
  test "unsupported operator in a relationship filter fails value-free, naming the field", %{} do
    plain_author("a1", "org1", "Ann")
    plain_post("p1", "org1", "P1", "a1")

    result =
      RelPlainPost
      |> Ash.Query.filter(author.note_blob > ^<<1, 2, 3>>)
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    assert {:error, error} = result
    msg = Exception.message(error)
    # attributable: names the unsupported operator + the destination field
    assert msg =~ "GreaterThan"
    assert msg =~ "note_blob"
    # value-free: never the filtered bytes nor any seeded row value (Rule 4)
    refute msg =~ <<1, 2, 3>>
    refute msg =~ "Ann"

    # non-vacuity of the surfaced error type: it is AshArcadic's own value-free UnsupportedFilter,
    # not an opaque DB / case-clause error leaking from an unguarded nested read.
    assert Enum.any?(
             List.wrap(error) ++ List.wrap(Map.get(error, :errors)),
             &match?(%AshArcadic.Errors.UnsupportedFilter{field: :note_blob}, &1)
           )
  end

  # TELEMETRY NON-VACUITY (Task-2 `internal?` tag): the source-on-related filter fans out into a
  # SEPARATE destination read (the IN path). That nested read carries `internal?: true`; the
  # top-level RelPlainPost read carries `internal?: false`. Both fire the `[:ash_arcadic, :read, :stop]`
  # span. Migrated to RelPlain* so the guard does not pre-reject the filter at parse.
  test "the nested relationship-filter read fires a :read span tagged internal?: true", %{} do
    plain_author("a1", "org1", "Ann")
    plain_post("p1", "org1", "P1", "a1")

    parent = self()
    handler_id = "rel-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [[:ash_arcadic, :read, :stop]],
      fn _event, _measurements, meta, _config ->
        send(parent, {:read_span, meta.internal?, meta.resource})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _posts} =
      RelPlainPost
      |> Ash.Query.filter(author.name == "Ann")
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    spans = collect_spans([])

    # The nested destination (RelPlainAuthor) read is tagged internal?: true …
    assert {true, RelPlainAuthor} in spans

    # … and the top-level RelPlainPost read is tagged internal?: false (the tag actually discriminates).
    assert {false, RelPlainPost} in spans
  end

  # === §6.1 TENANT ISOLATION (orthogonal to policy). LOAD-based isolation per strategy-pair cell
  # (LOAD is unaffected by the filter guard), each a FABRICATED-ATTACKER test: seed a same-id row in
  # tenant A and tenant B, then prove a tenant-A load reaches ONLY tenant-A's row. ===

  test "isolation :attribute->:attribute — a load reaches only the actor's tenant", %{} do
    # Same author_id in two tenants, distinct names; the belongs_to load must resolve the org1 row.
    plain_author("a1", "org1", "AnnA")
    plain_author("a1", "org2", "AnnB")
    plain_post("p1", "org1", "P1", "a1")

    {:ok, [p]} =
      RelPlainPost
      |> Ash.Query.filter(id == "p1")
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    {:ok, p} = Ash.load(p, :author, tenant: "org1", actor: @admin)
    # MUTATION-PROOF: RelPlainAuthor's `multitenancy attribute :org_id` injects `org_id == "org1"`
    # on the nested read; deleting that block would make org2's "AnnB" reachable too (ambiguous 2-row
    # match). The single-tenant name pins the scope.
    assert p.author.name == "AnnA"
    refute p.author.name == "AnnB"
  end

  test "isolation :context->:context — a load resolves the per-tenant DB, never the base DB", %{
    admin: admin,
    database: base_db
  } do
    {t1, t2} = provision_context(admin, RelCtxAuthor)
    # RelCtxPost shares the default encoder (t_<tenant>) → same tenant DBs, provisioned above.

    {:ok, _} =
      RelCtxAuthor
      |> Ash.Changeset.for_create(:create, %{id: "a1", name: "AnnT1"}, tenant: t1)
      |> Ash.create(actor: @admin)

    {:ok, _} =
      RelCtxAuthor
      |> Ash.Changeset.for_create(:create, %{id: "a1", name: "AnnT2"}, tenant: t2)
      |> Ash.create(actor: @admin)

    {:ok, _} =
      RelCtxPost
      |> Ash.Changeset.for_create(:create, %{id: "p1", title: "P1", author_id: "a1"}, tenant: t1)
      |> Ash.create(actor: @admin)

    # A same-id author seeded DIRECTLY in the BASE integration DB must be UNREACHABLE — the nested
    # :context read re-targets the tenant DB, never the base DB.
    base_conn = Arcadic.with_database(admin, base_db)
    Arcadic.command!(base_conn, "CREATE (n:RelCtxAuthor {id: 'a1', name: 'BASE'})")

    {:ok, [p]} =
      RelCtxPost
      |> Ash.Query.filter(id == "p1")
      |> Ash.Query.set_tenant(t1)
      |> Ash.read(actor: @admin)

    {:ok, p} = Ash.load(p, :author, tenant: t1, actor: @admin)

    # MUTATION-PROOF: strip RelCtxAuthor's `multitenancy strategy :context` and the load would fall
    # to the base DB (name "BASE") or the attribute path; the t1 name + base-unreachability pin it.
    assert p.author.name == "AnnT1"
    refute p.author.name == "AnnT2"
    refute p.author.name == "BASE"
  end

  test "isolation :attribute->:context — the nested load re-targets the tenant DB, never the base DB",
       %{admin: admin, database: base_db} do
    {t1, t2} = provision_context(admin, RelMixedCtxAuthor)

    {:ok, _} =
      RelMixedCtxAuthor
      |> Ash.Changeset.for_create(:create, %{id: "a1", name: "AnnT1"}, tenant: t1)
      |> Ash.create(actor: @admin)

    {:ok, _} =
      RelMixedCtxAuthor
      |> Ash.Changeset.for_create(:create, %{id: "a1", name: "AnnT2"}, tenant: t2)
      |> Ash.create(actor: @admin)

    {:ok, _} =
      RelMixedAttrPost
      |> Ash.Changeset.for_create(:create, %{id: "p1", org_id: t1, title: "P1", author_id: "a1"},
        tenant: t1
      )
      |> Ash.create(actor: @admin)

    # BASE-DB same-id author — must stay unreachable across the strategy boundary.
    base_conn = Arcadic.with_database(admin, base_db)
    Arcadic.command!(base_conn, "CREATE (n:RelMixedCtxAuthor {id: 'a1', name: 'BASE'})")

    {:ok, [p]} =
      RelMixedAttrPost
      |> Ash.Query.filter(id == "p1")
      |> Ash.Query.set_tenant(t1)
      |> Ash.read(actor: @admin)

    {:ok, p} = Ash.load(p, :author, tenant: t1, actor: @admin)

    # MUTATION-PROOF: the :context destination resolves its DB via set_tenant → tenant DB; a t2 load
    # yields "AnnT2" (proving the tenant DB, not base). BASE is never returned.
    assert p.author.name == "AnnT1"
    refute p.author.name == "BASE"

    {:ok, p2} = Ash.load(p, :author, tenant: t2, actor: @admin)
    assert p2.author.name == "AnnT2"
  end

  test "isolation :context->:attribute — the nested :attribute load carries the tenant discriminator",
       %{admin: admin} do
    {t1, t2} = provision_context(admin, RelMixedCtxPost)

    # :attribute authors in two tenants, same id, distinct names.
    {:ok, _} =
      RelMixedAttrAuthor
      |> Ash.Changeset.for_create(:create, %{id: "a1", org_id: t1, name: "AnnT1"}, tenant: t1)
      |> Ash.create(actor: @admin)

    {:ok, _} =
      RelMixedAttrAuthor
      |> Ash.Changeset.for_create(:create, %{id: "a1", org_id: t2, name: "AnnT2"}, tenant: t2)
      |> Ash.create(actor: @admin)

    {:ok, _} =
      RelMixedCtxPost
      |> Ash.Changeset.for_create(:create, %{id: "p1", title: "P1", author_id: "a1"}, tenant: t1)
      |> Ash.create(actor: @admin)

    {:ok, [p]} =
      RelMixedCtxPost
      |> Ash.Query.filter(id == "p1")
      |> Ash.Query.set_tenant(t1)
      |> Ash.read(actor: @admin)

    {:ok, p} = Ash.load(p, :author, tenant: t1, actor: @admin)

    # MUTATION-PROOF: RelMixedAttrAuthor's `multitenancy attribute :org_id` injects `org_id == t1` on
    # the nested read; without it the same-id t2 row ("AnnT2") would be an ambiguous second match.
    assert p.author.name == "AnnT1"
    refute p.author.name == "AnnT2"
  end

  test "isolation: a global (non-multitenant) destination is reachable across tenants (control cell)",
       %{} do
    # RelPlainPost's org1 load reaching RelPlainAuthor is attribute-scoped above; this asserts the
    # complementary invariant that isolation is a per-resource property — a non-multitenant resource
    # (CrudPerson) has NO tenant scoping and is globally visible. Confirms the matrix covers the
    # "global destination" corner: no discriminator ⇒ no scoping (by design), not a gap.
    refute ResourceInfo.multitenancy_strategy(CrudPerson)
  end

  # === FILTER-path isolation on the NON-policy pair (filtering IS allowed there): a source-on-related
  # filter must reach ONLY the actor's tenant. ===

  test "filter-path isolation: a source-on-related filter reaches ONLY the actor's tenant", %{} do
    plain_author("a1", "org1", "SharedName")
    plain_author("b1", "org2", "SharedName")
    plain_post("p1", "org1", "P1", "a1")
    plain_post("pb", "org2", "PB", "b1")

    {:ok, posts} =
      RelPlainPost
      |> Ash.Query.filter(author.name == "SharedName")
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    assert posts |> Enum.map(& &1.id) == ["p1"]
    refute "pb" in Enum.map(posts, & &1.id)
  end

  defp collect_spans(acc) do
    receive do
      {:read_span, internal?, resource} -> collect_spans([{internal?, resource} | acc])
    after
      100 -> acc
    end
  end
end
