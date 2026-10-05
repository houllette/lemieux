defmodule Mix.Tasks.LemieuxTasksTest do
  @moduledoc """
  What a project that depends on lemieux sees of its Mix tasks.

  Mix lists every dependency task that has a `@shortdoc` in that project's
  `mix help`. The research tasks below drive configurations and corpora that
  live in this repository and are not in the package, so they carry no
  shortdoc there; `mix help NAME` still prints their documentation. The agent
  extension tasks are documented workflows inside extension projects, so they
  stay listed, marked experimental.
  """

  use ExUnit.Case, async: true

  @label "**Experimental.** May change in any 0.x release."

  @repository_only [
    Mix.Tasks.Lemieux.Discovery,
    Mix.Tasks.Lemieux.Discovery.Confirm,
    Mix.Tasks.Lemieux.Discovery.Cycle,
    Mix.Tasks.Lemieux.Eval,
    Mix.Tasks.Lemieux.Eval.Bless,
    Mix.Tasks.Lmx.Harness.Bench
  ]

  # The documented name, which the module name decides.
  test "the workbench answers to the name its documentation uses" do
    assert Mix.Task.get("lemieux.extension.workbench") == Mix.Tasks.Lemieux.Extension.Workbench
    assert Mix.Task.get("lemieux.learning.extension.workbench") == nil
  end

  test "repository-only research tasks stay out of a consumer's mix help" do
    for task <- @repository_only do
      assert Code.ensure_loaded?(task)
      assert Mix.Task.shortdoc(task) == nil, "#{inspect(task)} still has a @shortdoc"
      assert Mix.Task.moduledoc(task) =~ ~r/\S/
    end
  end

  # Derived rather than listed: a listed set is how two of the six extension
  # tasks kept unmarked shortdocs while the test of the other four passed.
  test "every lemieux task a consumer's mix help lists says it is experimental" do
    listed = for task <- lemieux_tasks(), Mix.Task.shortdoc(task), do: task

    assert length(listed) == 6

    for task <- listed do
      assert Mix.Task.shortdoc(task) =~ ~r/\(experimental\)\z/, inspect(task)
    end
  end

  test "every lemieux research task opens its documentation with the label" do
    tasks = lemieux_tasks()

    assert length(tasks) == 11

    for task <- tasks do
      assert String.starts_with?(Mix.Task.moduledoc(task), @label), inspect(task)
    end
  end

  defp lemieux_tasks do
    for {:module, module} <- :application.get_key(:lemieux, :modules) |> elem(1) |> loaded(),
        String.starts_with?(inspect(module), "Mix.Tasks.Lemieux."),
        do: module
  end

  defp loaded(modules), do: Enum.map(modules, &Code.ensure_loaded/1)
end
