defmodule AshArcadic.Integration.RelationshipTest do
  use AshArcadic.Test.IntegrationCase
  require Ash.Query

  alias AshArcadic.Test.{RelAuthor, RelPost}

  @admin %{admin: true}

  setup %{admin: admin} do
    on_exit(fn ->
      Arcadic.command!(admin, "MATCH (n:RelAuthor) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:RelPost) DETACH DELETE n")
    end)

    :ok
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

  test "source-on-related filter (Post where author.name == X) via the separate-read IN path",
       %{} do
    author("a1", "org1", "Ann")
    author("a2", "org1", "Bob")
    post("p1", "org1", "P1", "a1")
    post("p2", "org1", "P2", "a2")

    {:ok, posts} =
      RelPost
      |> Ash.Query.filter(author.name == "Ann")
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    assert posts |> Enum.map(& &1.id) == ["p1"]
  end

  test "source-on-related != filter (Post where author.name != X)", %{} do
    author("a1", "org1", "Ann")
    author("a2", "org1", "Bob")
    post("p1", "org1", "P1", "a1")
    post("p2", "org1", "P2", "a2")

    {:ok, posts} =
      RelPost
      |> Ash.Query.filter(author.name != "Bob")
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    assert posts |> Enum.map(& &1.id) == ["p1"]
  end

  test "source-on-related IN filter (Post where author.name in [...]) via the batched IN read",
       %{} do
    author("a1", "org1", "Ann")
    author("a2", "org1", "Bob")
    author("a3", "org1", "Cy")
    post("p1", "org1", "P1", "a1")
    post("p2", "org1", "P2", "a2")
    post("p3", "org1", "P3", "a3")

    {:ok, posts} =
      RelPost
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
  # not byte-order-preserving (D27) — so the NESTED read (RelAuthor) fails closed with
  # %UnsupportedFilter{}. (The plan named `like/2`; that is NOT an Ash-core function — it silently
  # parses to a nil expression, a VACUOUS test. The range-op-on-:binary path is the verified
  # reachable UnsupportedFilter, mirroring the flat-path aggregate_test.exs idiom.)
  test "unsupported operator in a relationship filter fails value-free, naming the field", %{} do
    author("a1", "org1", "Ann")
    post("p1", "org1", "P1", "a1")

    result =
      RelPost
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
  # top-level RelPost read carries `internal?: false`. Both fire the `[:ash_arcadic, :read, :stop]`
  # span (verified event name against lib/ash_arcadic/telemetry.ex `:telemetry.span([:ash_arcadic, :read], …)`).
  test "the nested relationship-filter read fires a :read span tagged internal?: true", %{} do
    author("a1", "org1", "Ann")
    post("p1", "org1", "P1", "a1")

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
      RelPost
      |> Ash.Query.filter(author.name == "Ann")
      |> Ash.Query.set_tenant("org1")
      |> Ash.read(actor: @admin)

    spans = collect_spans([])

    # The nested destination (RelAuthor) read is tagged internal?: true …
    assert {true, RelAuthor} in spans

    # … and the top-level RelPost read is tagged internal?: false (the tag actually discriminates).
    assert {false, RelPost} in spans
  end

  defp collect_spans(acc) do
    receive do
      {:read_span, internal?, resource} -> collect_spans([{internal?, resource} | acc])
    after
      100 -> acc
    end
  end
end
