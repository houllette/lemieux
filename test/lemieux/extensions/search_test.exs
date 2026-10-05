defmodule Lemieux.Extensions.SearchTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Search
  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools

  test "adds grep and glob beside read in the default catalog" do
    assert {:ok, harness} = Harness.assemble(Harness.new(), [Search])
    assert Enum.map(harness.tools, &Tool.name/1) == ~w(read grep glob write edit bash)
  end

  test "keeps a search tool the catalog already has" do
    catalog = [Tools.Read, Tools.Grep, Tools.Write]
    assert {:ok, harness} = Harness.assemble(Harness.new(tools: catalog), [Search])
    assert harness.tools == [Tools.Read, Tools.Glob, Tools.Grep, Tools.Write]
  end

  test "leaves a catalog that cannot read alone" do
    assert {:ok, harness} = Harness.assemble(Harness.new(tools: [Tools.Bash]), [Search])
    assert harness.tools == [Tools.Bash]
  end

  test "the tools it adds are ones a read-only scout may carry" do
    assert {:ok, harness} = Harness.assemble(Harness.new(), [Search])
    searchers = Enum.filter(harness.tools, &(Tool.name(&1) in ["grep", "glob"]))
    assert Enum.all?(searchers, &Tool.read_only?/1)
  end
end
