defmodule Lemieux.Benchmark.Runtime.FixtureTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Grader.Command, as: CommandGrader
  alias Lemieux.Benchmark.Runtime.Fixture
  alias Lemieux.Benchmark.Task

  @moduletag :tmp_dir

  test "replays a recorded observation and applies its confined file writes", context do
    task = task(context.tmp_dir, "repair")

    fixture = %{
      "version" => 1,
      "observations" => %{
        "repair" => %{
          "answer" => "Repaired the fixture.",
          "tool_calls" => ["read", "write"],
          "writes" => %{"result.txt" => "fixed\n"},
          "usage" => %{"cost_usd" => 0.0, "input_tokens" => 12, "output_tokens" => 4}
        }
      }
    }

    assert {:ok, observation} = Fixture.run(task, observations: fixture)
    assert File.read!(Path.join(context.tmp_dir, "result.txt")) == "fixed\n"
    assert observation["changed_paths"] == ["result.txt"]
    assert observation["tool_calls"] == ["read", "write"]
    refute Map.has_key?(observation, "writes")
  end

  test "rejects fixture writes which escape the task workspace", context do
    task = task(context.tmp_dir, "escape")

    fixture = %{
      "version" => 1,
      "observations" => %{"escape" => %{"writes" => %{"../outside.txt" => "no"}}}
    }

    assert {:error, {:fixture_write, "../outside.txt", :outside_worktree}} =
             Fixture.run(task, observations: fixture)

    refute File.exists?(Path.join(context.tmp_dir, "../outside.txt"))
  end

  test "loads a versioned fixture set from disk", context do
    path = Path.join(context.tmp_dir, "observations.json")

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "observations" => %{"disk" => %{"answer" => "from disk"}}
      })
    )

    assert {:ok, %{"answer" => "from disk"}} =
             Fixture.run(task(context.tmp_dir, "disk"), path: path)
  end

  defp task(cwd, id) do
    %Task{
      id: id,
      prompt: "repair it",
      cwd: cwd,
      grader: %CommandGrader{command: ["sh", "-c", "true"]}
    }
  end
end
