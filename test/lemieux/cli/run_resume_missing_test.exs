defmodule Lemieux.CLI.RunResumeMissingTest do
  # `lmx run --resume NAME` with no stored session by that name is a wrong
  # argument: status 2, as `lmx run`'s contract has it, where it exited 1
  # under the category "other". The JSON result names no model, since no
  # transcript said which; it named the placeholder a new session would
  # have started on.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defp lmx(argv, %{tmp_dir: dir}) do
    opts = [
      store: JSONL.new(dir),
      supervisor: :"lemieux_run_resume_missing_#{System.unique_integer([:positive])}",
      cwd: dir,
      stdin_terminal?: true
    ]

    stdout =
      capture_io(fn ->
        capture_io(:stderr, fn -> send(self(), {:status, CLI.run(argv, opts)}) end)
      end)

    assert_received {:status, status}
    {status, stdout}
  end

  test "is a usage error, with no model in the JSON result", context do
    argv = ["run", "--config", "none", "--output-format", "json", "--resume", "nosuch", "hi"]
    {status, stdout} = lmx(argv, context)

    assert status == {:error, 2}

    result = JSON.decode!(stdout)
    assert result["exit_status"] == 2
    assert result["error"]["category"] == "usage"
    assert result["error"]["message"] =~ "no stored session has the id or name nosuch"
    assert result["model"] == nil
  end
end
