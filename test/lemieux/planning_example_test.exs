defmodule Lemieux.PlanningExampleTest do
  @moduledoc """
  The script extension in `examples/extensions/planning`, loaded the way `lmx`
  loads it. The example has no Mix project of its own, so this suite is where
  it is checked.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI.Extensions, as: CLIExtensions
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool

  @example Path.expand("../../examples/extensions/planning", __DIR__)

  @moduletag :tmp_dir

  test "the script loads through the CLI extension contract and adds plan_order alone" do
    assert {:ok, %{spec: spec}} = CLIExtensions.load(@example)
    assert {:ok, harness} = Harness.assemble(%Harness{tools: []}, [spec])

    assert Enum.map(harness.tools, &Tool.name/1) == ["plan_order"]
    assert :ok = Tool.validate_all(harness.tools)
    assert harness.hooks in [nil, []]
  end

  # The example used to re-apply the planning extension lmx already applies,
  # and every session it was loaded into stopped before its first request
  # with `{:duplicate_tool_name, "todo"}`. This is that session.
  test "an lmx run with the example loaded starts, offering todo once and plan_order once",
       %{tmp_dir: dir} do
    provider = Scripted.new([Scripted.complete("ok")])

    argv = ["run", "--model", "test:model", "--no-delegate", "--extension-dir", @example, "Ok?"]
    {status, stderr} = run_lmx(argv, provider, dir)

    assert status == :ok, stderr
    assert [request] = Scripted.requests(provider)

    names = Enum.map(request.tools, &Tool.name/1)
    assert Enum.count(names, &(&1 == "todo")) == 1
    assert Enum.count(names, &(&1 == "plan_order")) == 1
  end

  describe "plan_order" do
    setup do
      {:ok, %{spec: spec}} = CLIExtensions.load(@example)
      {:ok, %Harness{tools: [tool]}} = Harness.assemble(%Harness{tools: []}, [spec])
      %{tool: tool}
    end

    test "puts every step after the steps it depends on", %{tool: tool} do
      steps = [
        %{"id" => "deploy", "after" => ["migrate", "test"]},
        %{"id" => "test", "after" => ["write code"]},
        %{"id" => "migrate", "after" => ["review schema"]},
        %{"id" => "write code"},
        %{"id" => "review schema"}
      ]

      assert {:ok, order} = tool.run(%{"steps" => steps}, %{})

      assert order ==
               "1. write code\n2. test\n3. review schema\n4. migrate\n5. deploy"
    end

    test "keeps the given order among steps that are free to go next", %{tool: tool} do
      steps = [%{"id" => "c"}, %{"id" => "a"}, %{"id" => "b", "after" => []}]
      assert {:ok, "1. c\n2. a\n3. b"} = tool.run(%{"steps" => steps}, %{})
    end

    test "reports a cycle and every step it blocks instead of guessing", %{tool: tool} do
      steps = [
        %{"id" => "a", "after" => ["b"]},
        %{"id" => "b", "after" => ["a"]},
        %{"id" => "c", "after" => ["a"]},
        %{"id" => "free"}
      ]

      assert {:error, message} = tool.run(%{"steps" => steps}, %{})
      assert message == "no order exists: a dependency cycle blocks a, b, c"
    end

    test "refuses unknown dependencies, repeated ids and malformed steps", %{tool: tool} do
      assert {:error, unknown} =
               tool.run(%{"steps" => [%{"id" => "a", "after" => ["ghost"]}]}, %{})

      assert unknown =~ ~s("ghost", which is not a step)

      assert {:error, repeated} = tool.run(%{"steps" => [%{"id" => "a"}, %{"id" => "a"}]}, %{})
      assert repeated =~ ~s(step "a" appears twice)

      assert {:error, _} = tool.run(%{"steps" => [%{"id" => ""}]}, %{})
      assert {:error, _} = tool.run(%{"steps" => [%{"id" => "a", "after" => "b"}]}, %{})
      assert {:error, _} = tool.run(%{"steps" => []}, %{})
      assert {:error, _} = tool.run(%{}, %{})
    end
  end

  defp run_lmx(argv, provider, dir) do
    opts = [
      provider: provider,
      store: JSONL.new(Path.join(dir, "sessions")),
      supervisor: :"planning_example_#{System.unique_integer([:positive])}",
      cwd: dir,
      stdin_terminal?: true
    ]

    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn -> send(self(), {:status, Lemieux.CLI.run(argv, opts)}) end)
      end)

    assert_received {:status, status}
    {status, stderr}
  end
end
