defmodule Lemieux.ExtensionsTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tool

  test "coding defaults are an editable recipe, with no implicit interactive or network tools" do
    recipe = Extensions.coding("test:model", Scripted.new([]))
    assert Keyword.keys(recipe) == [:delegation]
    assert {:ok, harness} = Harness.assemble(Harness.new(), Keyword.values(recipe))
    assert Enum.map(harness.tools, &Tool.name/1) == ~w(read write edit bash delegate)
    assert Extensions.coding("test:model", Scripted.new([]), delegate: false) == []
  end

  test "interactive equipment can be selected and removed without replacing the recipe" do
    recipe = Extensions.coding("test:model", Scripted.new([]), interactive: true)
    assert Keyword.keys(recipe) == [:interactive, :delegation]

    assert {:ok, harness} =
             Harness.assemble(
               Harness.new(),
               recipe |> Keyword.delete(:delegation) |> Keyword.values()
             )

    assert Enum.map(harness.tools, &Tool.name/1) == ~w(read write edit bash ask_user)
  end
end
