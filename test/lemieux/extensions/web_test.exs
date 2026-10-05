defmodule Lemieux.Extensions.WebTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Web
  alias Lemieux.Extensions.Web.Brave
  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools
  alias Lemieux.Tools.WebFetch
  alias Lemieux.Tools.WebSearch

  defmodule Backend do
    @behaviour Lemieux.WebSearch.Backend

    @impl true
    def search(_state, _query, _opts), do: {:ok, [], %{}}
  end

  test "nothing consented to adds nothing" do
    assert {:ok, harness} = Harness.assemble(Harness.new(), [{Web, []}])

    assert harness.tools == nil
  end

  test "search then fetch, in that order, after the catalog" do
    assert {:ok, harness} =
             Harness.assemble(Harness.new(), [
               {Web, search: {Backend, :state}, search_cost_usd: 0.005, fetch: true}
             ])

    assert Enum.map(harness.tools, &Tool.name/1) ==
             ~w(read write edit bash web_search web_fetch research_check)

    assert %WebSearch{backend: {Backend, :state}, max_results: 5, max_cost_usd: 0.005} =
             Enum.find(harness.tools, &(Tool.name(&1) == "web_search"))

    assert %WebFetch{unsafe_allow_loopback_for_tests: false} =
             Enum.find(harness.tools, &(Tool.name(&1) == "web_fetch"))

    assert harness.system =~ "list the distinct facts"
    assert harness.system =~ "research_check"
  end

  test "research guidance is absent without both tools and respects a disabled prompt" do
    assert {:ok, search_only} =
             Harness.assemble(Harness.new(), [{Web, search: {Backend, :state}}])

    assert search_only.system == :default

    assert {:ok, no_prompt} =
             Harness.assemble(Harness.new(system: nil), [
               {Web, search: {Backend, :state}, fetch: true}
             ])

    assert no_prompt.system == nil
  end

  test "fetch alone" do
    assert {:ok, harness} =
             Harness.assemble(Harness.new(tools: [Tools.Read]), [{Web, fetch: true}])

    assert Enum.map(harness.tools, &Tool.name/1) == ~w(read web_fetch)
  end

  test "a catalog that already carries the tool gets the configured one in its place" do
    stale = WebSearch.new(backend: {Backend, :old}, max_results: 1)

    assert {:ok, harness} =
             Harness.assemble(Harness.new(tools: [stale, Tools.Read]), [
               {Web, search: {Backend, :new}}
             ])

    assert Enum.map(harness.tools, &Tool.name/1) == ~w(read web_search)
    assert %WebSearch{backend: {Backend, :new}} = List.last(harness.tools)
  end

  test "provenance names the backend module and never its state" do
    backend = Brave.new(api_key: "super-secret")

    assert {:ok, harness} =
             Harness.assemble(Harness.new(), [
               {Web, search: {Brave, backend}, search_cost_usd: Brave.request_cost_usd(backend)}
             ])

    assert [%{"options" => %{"search" => "Lemieux.Extensions.Web.Brave", "fetch" => false}}] =
             harness.applied

    refute inspect(harness.applied) =~ "super-secret"
  end

  test "a backend that is not {module, state} is refused" do
    assert {:error, {Web, {:invalid_search_backend, "brave"}}} =
             Harness.assemble(Harness.new(), [{Web, search: "brave"}])
  end
end
