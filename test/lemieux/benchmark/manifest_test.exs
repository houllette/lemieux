defmodule Lemieux.Benchmark.ManifestTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Manifest

  @moduletag :tmp_dir

  test "reads tasks and resolves their working directories relative to the manifest", context do
    json =
      JSON.encode!(%{
        "version" => 1,
        "metadata" => %{"suite" => "smoke"},
        "tasks" => [
          %{
            "id" => "compile",
            "prompt" => "make it compile",
            "cwd" => "fixture",
            "grader" => %{"command" => ["sh", "-c", "test -f solved.txt"]}
          }
        ]
      })

    path = Path.join(context.tmp_dir, "manifest.json")
    File.write!(path, json)

    assert {:ok, manifest} = Manifest.read(path)
    assert manifest.metadata == %{"suite" => "smoke"}
    assert [task] = manifest.tasks
    assert task.id == "compile"
    assert task.cwd == Path.join(context.tmp_dir, "fixture")
    assert task.grader.command == ["sh", "-c", "test -f solved.txt"]
  end

  test "rejects unknown versions, duplicate ids and malformed graders", context do
    assert {:error, {:unsupported_version, 2}} =
             Manifest.decode(~s({"version":2,"tasks":[]}), context.tmp_dir)

    duplicate = %{
      "version" => 1,
      "tasks" => [task("same"), task("same")]
    }

    assert {:error, :duplicate_task_id} =
             Manifest.decode(JSON.encode!(duplicate), context.tmp_dir)

    malformed = %{"version" => 1, "tasks" => [Map.put(task("bad"), "grader", %{})]}

    assert {:error, message} = Manifest.decode(JSON.encode!(malformed), context.tmp_dir)
    assert message =~ "grader.command"
  end

  defp task(id) do
    %{
      "id" => id,
      "prompt" => "fix it",
      "grader" => %{"command" => ["sh", "-c", "true"]}
    }
  end
end
