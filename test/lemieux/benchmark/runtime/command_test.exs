defmodule Lemieux.Benchmark.Runtime.CommandTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Runtime.Command
  alias Lemieux.Benchmark.Task

  @moduletag :tmp_dir

  test "passes prompt and task placeholders as argv without shell interpolation", context do
    task = %Task{
      id: "argv",
      prompt: "literal ; $HOME",
      cwd: context.tmp_dir,
      grader: %Lemieux.Benchmark.Grader.Command{command: ["sh", "-c", "true"]}
    }

    assert {:ok, observation} =
             Command.run(task,
               command: ["printf", "%s|%s", "{task_id}", "{prompt}"]
             )

    assert observation["status"] == "completed"
    assert observation["answer"] == "argv|literal ; $HOME"
    assert observation["exit_status"] == 0
  end

  test "reports a non-zero command as an observation so the grader may still inspect its work",
       context do
    task = %Task{
      id: "nonzero",
      prompt: "try",
      cwd: context.tmp_dir,
      grader: %Lemieux.Benchmark.Grader.Command{command: ["sh", "-c", "true"]}
    }

    assert {:ok, observation} =
             Command.run(task, command: ["sh", "-c", "printf partial; exit 7"])

    assert observation["status"] == "failed"
    assert observation["answer"] == "partial"
    assert observation["exit_status"] == 7
  end
end
