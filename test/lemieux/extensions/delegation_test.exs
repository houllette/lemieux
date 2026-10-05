defmodule Lemieux.Extensions.DelegationTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Delegation
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Delegate
  alias Lemieux.Tool
  alias Lemieux.Tools

  @moduletag :tmp_dir

  test "apply uses the snapshot prepared by init even if the directory disappears", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir!(root)
    assert {:ok, state} = Delegation.init(model: "test:model", priced?: false, cwd: root)
    assert state.snapshot["cwd"] == root
    File.rmdir!(root)
    first = Delegation.apply(Harness.new(), state)
    assert first == Delegation.apply(Harness.new(), state)
    assert List.last(first.tools).snapshot == state.snapshot
  end

  test "appends one delegate tool holding the repository scout", %{tmp_dir: tmp_dir} do
    provider = Scripted.new([], estimated_cost_usd: 0.001)

    assert {:ok, harness} =
             Harness.assemble(Harness.new(), [
               {Delegation, model: "test:model", provider: provider, cwd: tmp_dir}
             ])

    assert Enum.map(harness.tools, &Tool.name/1) == ~w(read write edit bash delegate)
    assert %Delegate{} = delegate = List.last(harness.tools)

    assert [%Definition{id: "repository-scout", model: "test:model", tools: tools}] =
             Map.values(delegate.definitions)

    # It searches as well as reads, every tool it holds only reads, and the
    # model deciding whether to delegate is told so.
    assert Enum.map(tools, &Tool.name/1) == ~w(read grep glob)
    assert Enum.all?(tools, &Tool.read_only?/1)
    assert Tool.description(delegate) =~ "repository-scout: Search the working tree (grep, glob)"

    assert [%{"module" => "Lemieux.Extensions.Delegation", "options" => options}] =
             harness.applied

    assert options == %{
             "definitions" => ["repository-scout"],
             "model" => "test:model",
             "priced" => true
           }
  end

  test "leaves a catalog that already delegates alone" do
    existing =
      Delegate.new([Delegation.repository_scout("test:model", true)],
        max_cost_usd: 1.0,
        snapshot: %{"kind" => "test", "version" => 1}
      )

    assert {:ok, harness} =
             Harness.assemble(Harness.new(tools: [Tools.Read, existing]), [
               {Delegation, model: "test:model", priced?: true}
             ])

    assert harness.tools == [Tools.Read, existing]
  end

  # A dollar cap on a route that cannot price a request is a stop, not a
  # bound, so the scout is bounded in requests there and its output is left
  # alone.
  test "the scout is bounded in whichever currency the route can enforce" do
    priced = Delegation.repository_scout("test:model", true)
    assert priced.max_cost_usd == 3.0
    assert priced.max_requests == nil

    unpriced = Delegation.repository_scout("test:model", false)
    assert unpriced.max_cost_usd == nil
    assert unpriced.max_requests == 480
  end

  test "priced? asks the provider, not the model string" do
    assert Delegation.priced?(Scripted.new([], estimated_cost_usd: 0.001), "test:model")
    refute Delegation.priced?(Scripted.new([]), "test:model")
  end

  test "host overrides fold into the tool under the budgets", %{tmp_dir: tmp_dir} do
    child = Scripted.new([])

    assert {:ok, harness} =
             Harness.assemble(Harness.new(tools: []), [
               {Delegation,
                model: "test:model",
                priced?: false,
                cwd: tmp_dir,
                options: [providers: %{"repository-scout" => child}, max_cost_usd: 0.01]}
             ])

    assert [%Delegate{} = delegate] = harness.tools
    assert delegate.options[:providers] == %{"repository-scout" => child}
    assert delegate.max_cost_usd == 9.0
    assert delegate.max_requests == 2_880
    assert delegate.snapshot["cwd"] == tmp_dir
  end
end
