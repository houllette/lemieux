defmodule VerifierExtension.CheckTest do
  use ExUnit.Case, async: true

  alias VerifierExtension.Check

  @moduletag :tmp_dir

  # A scripted environment: `run/3` replays the events it was built with, so
  # every terminal event the environment contract allows can be exercised
  # without a real process.
  defmodule Replay do
    def run(events, _command, _opts), do: {:ok, events}
  end

  defmodule Broken do
    def run(reason, _command, _opts), do: {:error, reason}
  end

  test "a passing command reports its output and status", %{tmp_dir: dir} do
    assert %{"status" => "passed", "exit_status" => 0, "output" => "ok\n"} =
             result = Check.run("echo ok", dir, timeout_ms: 5_000)

    assert result["command"] == "echo ok"
    assert is_integer(result["duration_ms"])
  end

  test "a non-zero exit is a failed check, not a broken runner", %{tmp_dir: dir} do
    assert %{"status" => "failed", "exit_status" => 3, "output" => "nope\n"} =
             Check.run("echo nope >&2; exit 3", dir, timeout_ms: 5_000)
  end

  test "a command past its deadline is killed and reported as timed out", %{tmp_dir: dir} do
    started = System.monotonic_time(:millisecond)

    assert %{"status" => "timed_out", "exit_status" => nil} =
             Check.run("sleep 5", dir, timeout_ms: 200)

    assert System.monotonic_time(:millisecond) - started < 4_000
  end

  test "output keeps the head and the tail within the cap", %{tmp_dir: dir} do
    command = "i=0; while [ $i -lt 3000 ]; do echo \"line $i\"; i=$((i+1)); done; echo END"

    assert %{"status" => "passed", "output" => output} =
             Check.run(command, dir, timeout_ms: 5_000, max_output_bytes: 2_000)

    assert String.starts_with?(output, "line 0\n")
    assert String.ends_with?(output, "END\n")
    assert output =~ ~r/\.\.\. \[\d+ bytes omitted\] \.\.\./
    assert byte_size(output) < 2_200
  end

  test "an environment output limit and a transport failure are named", %{tmp_dir: dir} do
    limit = {Replay, [{:data, "partial"}, {:output_limit, 8}]}

    assert %{"status" => "output_limit", "output" => "partial", "exit_status" => nil} =
             Check.run("noisy", dir, environment: limit)

    failed = {Replay, [{:failed, :pipe_closed}]}

    assert %{"status" => "failed_to_run", "error" => ":pipe_closed"} =
             Check.run("x", dir, environment: failed)

    assert %{"status" => "failed_to_run", "error" => ":enoent"} =
             Check.run("x", dir, environment: {Broken, :enoent})
  end

  test "invalid bytes are replaced so the record stays JSON-encodable", %{tmp_dir: dir} do
    env = {Replay, [{:data, <<"ok", 255, "\n">>}, {:exit_status, 0}]}
    assert %{"output" => output} = Check.run("x", dir, environment: env)
    assert String.valid?(output)
    assert JSON.encode!(output) =~ "ok"
  end

  test "excerpts keep the tail, starting on a line boundary" do
    output = Enum.map_join(1..50, "", &"line #{&1}\n")
    excerpt = Check.excerpt(output, 60)
    assert String.starts_with?(excerpt, "... [")
    assert String.contains?(excerpt, "bytes omitted] ...\nline ")
    assert String.ends_with?(excerpt, "line 50\n")
    assert byte_size(excerpt) < 120
    assert Check.excerpt("short\n", 60) == "short\n"
  end
end
