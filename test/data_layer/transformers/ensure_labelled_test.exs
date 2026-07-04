defmodule AshArcadic.DataLayer.Transformers.EnsureLabelledTest do
  use ExUnit.Case, async: true

  alias Spark.Dsl.Extension

  # Target the transformer's EFFECT directly: pre-transformer the :label DSL option
  # is nil; the transformer sets it. (Info.label/1 has a default_label fallback, so
  # asserting through it would be green WITHOUT the transformer — a vacuous tripwire.)
  test "a resource with no explicit label has :label set to its short module name" do
    assert Extension.get_opt(AshArcadic.Test.Unlabelled, [:arcade], :label) == "Unlabelled"
  end
end
