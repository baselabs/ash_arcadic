defmodule AshArcadic.Test.CalcRelAuthzTest do
  @moduledoc """
  Closeout security tripwire (Slice-7): a relationship-path expression calc on the LOAD path must
  FAIL CLOSED value-free — never route through the data layer's Elixir eval, which would trigger
  Ash's `Ash.load!(..., authorize?: false)` fallback for the unloaded relationship and read the
  related resource WITHOUT its row/field policies (an authorization bypass; the leaf name `:id`
  collides with a source stored attribute so the load-gate name check alone passes it).

  Filter/sort already reject relationship-path refs (`AshArcadic.Query.Expression`); the load gate
  (`add_calculations/3` → `calc_supported?/2`) must mirror that rejection.
  """
  use AshArcadic.Test.IntegrationCase
  require Ash.Query
  import Ash.Expr
  alias AshArcadic.Test.RelAuthor
  alias AshArcadic.Test.RelPost

  @admin %{admin: true}
  @nonadmin %{admin: false}

  setup %{admin: admin} do
    # An UNLISTED author — RelAuthor's row policy (`listed == true`) hides it from a non-admin.
    {:ok, _} =
      Ash.create(RelAuthor, %{id: "hiddenA", org_id: "o1", name: "Hidden", listed: false},
        actor: @admin,
        tenant: "o1"
      )

    {:ok, _} =
      Ash.create(RelPost, %{id: "rp1", org_id: "o1", title: "T", author_id: "hiddenA"},
        actor: @admin,
        tenant: "o1"
      )

    on_exit(fn ->
      Arcadic.command!(admin, "MATCH (n:RelPost) DETACH DELETE n")
      Arcadic.command!(admin, "MATCH (n:RelAuthor) DETACH DELETE n")
    end)

    :ok
  end

  test "TRIPWIRE: a relationship-path calc on the LOAD path fails closed (no authz-bypass leak)" do
    # Sanity: the non-admin genuinely cannot read the unlisted author directly.
    {:ok, authors} = Ash.read(RelAuthor, actor: @nonadmin, tenant: "o1")
    refute Enum.any?(authors, &(&1.id == "hiddenA"))

    # `expr(author.id)` — leaf `:id` collides with RelPost's local stored `:id`. Must FAIL CLOSED,
    # not compute the related author's id via the unauthorized fallback load.
    q =
      RelPost
      |> Ash.Query.filter(id == "rp1")
      |> Ash.Query.calculate(:leaked_author_id, :string, expr(author.id))

    assert {:error, error} = Ash.read(q, actor: @nonadmin, tenant: "o1")
    msg = Exception.message(error)
    # value-free: the error names the class, never the hidden author's id.
    refute msg =~ "hiddenA"
  end
end
