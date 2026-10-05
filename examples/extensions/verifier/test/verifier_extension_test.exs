defmodule VerifierExtensionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Agent
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  @fixtures Path.expand("fixtures", __DIR__)
  @receipt_fix """
  #!/bin/sh
  # Prints one receipt line: NAME AMOUNT.
  cents=$2
  printf '%s %d.%02d\\n' "$1" $(( cents / 100 )) $(( cents % 100 ))
  """
  @summary_fix """
  #!/bin/sh
  # Prints one summary line: DATE TOTAL.
  cents=$2
  printf '%s %d.%02d\\n' "$1" $(( cents / 100 )) $(( cents % 100 ))
  """

  setup %{tmp_dir: tmp_dir} do
    {:ok, log} = Elixir.Agent.start_link(fn -> [] end)
    %{log: log, sessions: Path.join(tmp_dir, "sessions")}
  end

  defp workspace(tmp_dir, fixture) do
    cwd = Path.join(tmp_dir, fixture)
    File.cp_r!(Path.join(@fixtures, fixture), cwd)
    cwd
  end

  defp options(provider, context, extra \\ []) do
    Keyword.merge(
      [
        provider: provider,
        model: "test:model",
        supervisor: :"verifier_example_#{System.unique_integer([:positive])}",
        sessions_dir: context.sessions,
        session_options: [max_turns: 4],
        verify_timeout_ms: 5_000
      ],
      extra
    )
  end

  defp usage, do: %{"input_tokens" => 10, "output_tokens" => 3}

  # A session's `write` replaces only a file it has read (see
  # `Lemieux.Tool.FileState`), so each scripted fix reads its file first, as a
  # model would.
  defp read(id, path), do: Scripted.tool_call(id, "read", %{"path" => path}, usage: usage())

  defp write(id, path, content),
    do: Scripted.tool_call(id, "write", %{"path" => path, "content" => content}, usage: usage())

  defp done(text), do: Scripted.complete(text, usage: usage())

  # Records the prompt a session was opened with, then behaves like `turn`.
  defp recording(log, turn) do
    fn request ->
      prompt =
        request.entries
        |> Enum.filter(&(&1.type == :user))
        |> Enum.map(& &1.payload["text"])
        |> List.first()

      Elixir.Agent.update(log, &[prompt | &1])
      turn
    end
  end

  test "a wrong second call site fails the project's own check and is fixed on retry",
       context do
    cwd = workspace(context.tmp_dir, "ledger")

    provider =
      Scripted.new([
        read("r1", "bin/receipt.sh"),
        write("w1", "bin/receipt.sh", @receipt_fix),
        done("Fixed the receipt renderer."),
        recording(context.log, read("r2", "bin/summary.sh")),
        write("w2", "bin/summary.sh", @summary_fix),
        done("Fixed the summary renderer too.")
      ])

    input = %{prompt: "Render every amount with two decimals.", cwd: cwd, timeout_ms: 30_000}
    assert {:ok, observation} = Agent.run(VerifierExtension, input, options(provider, context))

    assert %{
             "command" => "sh tests/run.sh",
             "discovered_from" => "tests/run.sh",
             "first_status" => "failed",
             "retry?" => true,
             "final_status" => "passed",
             "retry_changed_tests" => []
           } = observation["verification"]

    assert [
             %{"status" => "failed", "exit_status" => 1, "output" => first},
             %{"status" => "passed"}
           ] =
             observation["verification"]["runs"]

    assert first =~ "PASS bin/receipt.sh"
    assert first =~ "FAIL bin/summary.sh"

    assert observation["status"] == "completed"
    assert observation["answer"] == "Fixed the summary renderer too."
    assert [task_id, retry_id] = observation["session_ids"]
    assert task_id != retry_id
    assert observation["session_id"] == retry_id
    assert [%{"role" => "task"}, %{"role" => "retry"}] = observation["sessions"]
    assert Enum.all?(observation["sessions"], &(not Map.has_key?(&1, "transcript")))
    assert length(observation["transcript"]) > 4

    # Usage covers both sessions: six scripted requests at ten tokens each.
    assert observation["usage"]["requests"] == 6
    assert observation["usage"]["input_tokens"] == 60
    assert observation["usage"]["direct"]["requests"] == 6

    # The retry was told what failed, and how, without being pointed at check.sh.
    assert [retry_prompt] = Elixir.Agent.get(context.log, & &1)
    assert retry_prompt =~ "Render every amount with two decimals."
    assert retry_prompt =~ "sh tests/run.sh"
    assert retry_prompt =~ "exit status 1"
    assert retry_prompt =~ "FAIL bin/summary.sh"
    assert retry_prompt =~ "without editing the tests"
    refute retry_prompt =~ "check.sh"

    # The task session ran the host's prompt unchanged.
    assert [first_request | _rest] = Scripted.requests(provider)

    assert [%{payload: %{"text" => task_prompt}}] =
             Enum.filter(first_request.entries, &(&1.type == :user))

    assert task_prompt == input.prompt

    refute Enum.any?(observation["verification"]["runs"], &(&1["command"] =~ "check.sh"))
    assert File.read!(Path.join(cwd, "bin/summary.sh")) == @summary_fix
    assert {"Tea 3.05\n", 0} = System.cmd("sh", ["bin/receipt.sh", "Tea", "305"], cd: cwd)
  end

  test "a passing first run is not retried", context do
    cwd = workspace(context.tmp_dir, "ledger")

    provider =
      Scripted.new([
        Scripted.tool_calls(
          [
            %{id: "r1", name: "read", arguments: %{"path" => "bin/receipt.sh"}},
            %{id: "r2", name: "read", arguments: %{"path" => "bin/summary.sh"}}
          ],
          usage: usage()
        ),
        Scripted.tool_calls(
          [
            %{
              id: "w1",
              name: "write",
              arguments: %{"path" => "bin/receipt.sh", "content" => @receipt_fix}
            },
            %{
              id: "w2",
              name: "write",
              arguments: %{"path" => "bin/summary.sh", "content" => @summary_fix}
            }
          ],
          usage: usage()
        ),
        done("Both renderers print two decimals.")
      ])

    input = %{prompt: "Render every amount with two decimals.", cwd: cwd, timeout_ms: 30_000}
    assert {:ok, observation} = Agent.run(VerifierExtension, input, options(provider, context))

    assert %{"first_status" => "passed", "retry?" => false, "final_status" => "passed"} =
             observation["verification"]

    assert [_task] = observation["session_ids"]
    assert [%{"status" => "passed"}] = observation["verification"]["runs"]
    assert length(Scripted.requests(provider)) == 3
    assert observation["answer"] == "Both renderers print two decimals."
  end

  test "a workspace with no discoverable command is reported and not retried", context do
    cwd = workspace(context.tmp_dir, "bare")

    provider =
      Scripted.new([
        Scripted.tool_call(
          "e1",
          "edit",
          %{"path" => "app.conf", "old" => "mode=broken", "new" => "mode=fixed"},
          usage: usage()
        ),
        done("Changed mode=broken to mode=fixed.")
      ])

    input = %{
      prompt: "Change mode=broken to mode=fixed in app.conf.",
      cwd: cwd,
      timeout_ms: 30_000
    }

    assert {:ok, observation} = Agent.run(VerifierExtension, input, options(provider, context))

    assert observation["verification"] == %{
             "command" => nil,
             "discovered_from" => nil,
             "first_status" => "not_run",
             "retry?" => false,
             "final_status" => "not_run",
             "runs" => [],
             "retry_changed_tests" => []
           }

    assert [_task] = observation["session_ids"]
    assert File.read!(Path.join(cwd, "app.conf")) == "mode=fixed\n"
  end

  test "an explicit verify_command replaces discovery", context do
    cwd = workspace(context.tmp_dir, "bare")
    provider = Scripted.new([done("Nothing to do.")])
    input = %{prompt: "Look around.", cwd: cwd, timeout_ms: 30_000}

    assert {:ok, observation} =
             Agent.run(
               VerifierExtension,
               input,
               options(provider, context,
                 verify_command: "test \"$(cat app.conf)\" = mode=broken"
               )
             )

    assert %{
             "command" => "test \"$(cat app.conf)\" = mode=broken",
             "discovered_from" => "verify_command",
             "first_status" => "passed",
             "retry?" => false
           } = observation["verification"]
  end

  test "a check that outruns its deadline is killed, retried once and bounded", context do
    cwd = workspace(context.tmp_dir, "slow")
    provider = Scripted.new([done("Done."), recording(context.log, done("Still done."))])
    input = %{prompt: "Make the suite pass.", cwd: cwd, timeout_ms: 30_000}
    started = System.monotonic_time(:millisecond)

    assert {:ok, observation} =
             Agent.run(
               VerifierExtension,
               input,
               options(provider, context, verify_timeout_ms: 200)
             )

    assert System.monotonic_time(:millisecond) - started < 5_000

    assert %{"first_status" => "timed_out", "retry?" => true, "final_status" => "timed_out"} =
             observation["verification"]

    assert [%{"status" => "timed_out", "exit_status" => nil}, %{"status" => "timed_out"}] =
             observation["verification"]["runs"]

    assert [retry_prompt] = Elixir.Agent.get(context.log, & &1)
    assert retry_prompt =~ "timed out after 200ms"
    assert observation["status"] == "completed"
    assert observation["answer"] == "Still done."
  end

  test "a retry that edits the tests is recorded as evidence", context do
    cwd = workspace(context.tmp_dir, "ledger")

    provider =
      Scripted.new([
        done("Looks fine to me."),
        read("r1", "tests/run.sh"),
        write("w1", "tests/run.sh", "#!/bin/sh\nexit 0\n"),
        done("Made the suite pass.")
      ])

    input = %{prompt: "Render every amount with two decimals.", cwd: cwd, timeout_ms: 30_000}
    assert {:ok, observation} = Agent.run(VerifierExtension, input, options(provider, context))

    assert %{"final_status" => "passed", "retry_changed_tests" => ["tests/run.sh"]} =
             observation["verification"]
  end

  test "a session that does not complete still gets its check and reports failure", context do
    cwd = workspace(context.tmp_dir, "ledger")
    provider = Scripted.new([])
    input = %{prompt: "Render every amount with two decimals.", cwd: cwd, timeout_ms: 30_000}

    assert {:error, :agent_failed, observation} =
             Agent.run(VerifierExtension, input, options(provider, context))

    assert observation["status"] == "failed"

    assert %{"first_status" => "failed", "retry?" => true, "final_status" => "failed"} =
             observation["verification"]

    assert length(observation["session_ids"]) == 2
  end

  test "the observation is JSON and carries no atoms from the pipeline", context do
    cwd = workspace(context.tmp_dir, "ledger")
    provider = Scripted.new([done("Skipped."), done("Skipped again.")])
    input = %{prompt: "Render every amount with two decimals.", cwd: cwd, timeout_ms: 30_000}
    assert {:ok, observation} = Agent.run(VerifierExtension, input, options(provider, context))
    assert is_binary(JSON.encode!(observation))
  end
end
