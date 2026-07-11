defmodule AshArcadic.Query.WriteTest do
  @moduledoc false
  use ExUnit.Case, async: true
  require Ash.Expr

  alias AshArcadic.Errors.UnsupportedFilter
  alias AshArcadic.Query.Write
  alias AshArcadic.Test.CalcPerson
  alias AshArcadic.Test.CalcTenantPerson, as: TenantP
  alias AshArcadic.Test.CrudPerson

  # Build a changeset carrying atomics + static attributes exactly as Ash's
  # fully_atomic_changeset hands the callback (hydrated exprs — proven in
  # scratchpad/probe_fac.exs).
  defp atomic_cs(resource, record_attrs, static, atomics) do
    cs =
      resource
      |> struct(record_attrs)
      |> Ash.Changeset.for_update(:update, static)

    Enum.reduce(atomics, cs, fn {field, expr}, acc ->
      Ash.Changeset.atomic_update(acc, field, expr)
    end)
  end

  test "atomic increment translates to a SET fragment referencing the row" do
    cs = atomic_cs(CrudPerson, %{id: "p1", age: 10}, %{}, age: Ash.Expr.expr(age + 1))

    assert {:ok, set_clause, params} = Write.build_set(CrudPerson, cs, %{})
    assert set_clause =~ "n.age = (n.age + $"
    # The literal 1 is a bound param, never interpolated.
    assert Enum.any?(params, fn {_k, v} -> v == 1 end)
    refute set_clause =~ "$static"
  end

  test "static attributes render as `n += $static` with the cast map bound" do
    cs = atomic_cs(CrudPerson, %{id: "p1"}, %{name: "New"}, [])

    assert {:ok, set_clause, params} = Write.build_set(CrudPerson, cs, %{})
    assert set_clause == "n += $static"
    assert params["static"] == %{"name" => "New"}
  end

  test "atomic + static compose (atomic fragment, then `n += $static`)" do
    cs = atomic_cs(CrudPerson, %{id: "p1", age: 10}, %{name: "New"}, age: Ash.Expr.expr(age + 5))

    assert {:ok, set_clause, params} = Write.build_set(CrudPerson, cs, %{})
    assert set_clause =~ ~r/^n\.age = \(n\.age \+ \$\w+\), n \+= \$static$/
    assert params["static"] == %{"name" => "New"}
  end

  test "a fully-empty SET fails closed value-free" do
    cs = atomic_cs(CrudPerson, %{id: "p1"}, %{}, [])
    assert {:error, %UnsupportedFilter{}} = Write.build_set(CrudPerson, cs, %{})
  end

  test "writing the :attribute multitenancy discriminator via a STATIC change fails closed" do
    # org_id is CalcTenantPerson's discriminator (multitenancy attribute :org_id).
    cs = atomic_cs(TenantP, %{id: "p1", org_id: "org1"}, %{org_id: "org2"}, [])

    assert {:error, %UnsupportedFilter{operator: _, field: :org_id}} =
             Write.build_set(TenantP, cs, %{})
  end

  test "writing the discriminator via an ATOMIC change fails closed" do
    cs = atomic_cs(TenantP, %{id: "p1", org_id: "org1"}, %{}, org_id: Ash.Expr.expr(org_id))
    assert {:error, %UnsupportedFilter{field: :org_id}} = Write.build_set(TenantP, cs, %{})
  end

  test "resource IS threaded so Expression's sensitive/non-stored guard stays live" do
    # amount is :decimal on CrudPerson: value_translatable (stored, non-sensitive) so it CLEARS the
    # LHS target guard, then Expression.ref_ok? rejects the :decimal RHS ref (range-incomparable).
    # Both guards — and hydrate_refs — key on the threaded resource; a resource-less %Query{} would
    # fail hydration / bypass ref_ok?'s fail-safe (V2). So a reject here proves the REAL resource is
    # threaded into build_set's working query.
    cs =
      atomic_cs(CrudPerson, %{id: "p1", amount: Decimal.new("1")}, %{},
        amount: Ash.Expr.expr(amount)
      )

    assert {:error, %UnsupportedFilter{field: :amount}} = Write.build_set(CrudPerson, cs, %{})
  end

  test "atomic SET targeting a SENSITIVE field fails closed value-free (spec §7.1 — no plaintext to encrypted-binary)" do
    # :secret is CalcPerson's sensitive :binary attribute. An atomic SET with a BENIGN literal RHS
    # (1 + 1) would emit `n.secret = 2` — raw plaintext into an app-side-encrypted field — because
    # Expression only guards RHS *refs*, not the LHS target. The reject must come from build_set's
    # OWN LHS guard (Info.value_translatable_field?/2, the Slice-7 predicate). The SAME predicate is
    # false for a non-stored (`skip`) target, so this one guard covers both spec-§7.1 target classes.
    cs = atomic_cs(CalcPerson, %{id: "p1", secret: <<1>>}, %{}, secret: Ash.Expr.expr(1 + 1))
    assert {:error, %UnsupportedFilter{field: :secret}} = Write.build_set(CalcPerson, cs, %{})
  end

  test "seed params are preserved and atomic params never collide with them" do
    cs = atomic_cs(CrudPerson, %{id: "p1", age: 10}, %{}, age: Ash.Expr.expr(age + 1))
    seed = %{"param1" => 5, "param2" => "org1"}

    assert {:ok, _set, params} = Write.build_set(CrudPerson, cs, seed)
    assert params["param1"] == 5
    assert params["param2"] == "org1"
    # The atomic literal got a fresh key (param3+), not clobbering the seed.
    assert map_size(params) >= 3
  end

  describe "AshArcadic.Query.where_and_params/1" do
    test "renders the accumulated filters as a WHERE clause with params" do
      q = %AshArcadic.Query{
        resource: CrudPerson,
        label: :CrudPerson,
        filters: ["(n.age > $param1 AND n.name = $param2)"],
        params: %{"param1" => 30, "param2" => "Ann"}
      }

      assert {"WHERE (n.age > $param1 AND n.name = $param2)",
              %{"param1" => 30, "param2" => "Ann"}} =
               AshArcadic.Query.where_and_params(q)
    end

    test "an empty filter set yields an empty WHERE string" do
      q = %AshArcadic.Query{resource: CrudPerson, label: :CrudPerson, filters: [], params: %{}}
      assert {"", %{}} = AshArcadic.Query.where_and_params(q)
    end
  end
end
