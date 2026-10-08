defmodule Lemieux.Tools.BashTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tool
  alias Lemieux.Tools.Bash

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{
      ctx: %{
        cwd: tmp_dir,
        session_id: "s1",
        call_id: "c1",
        environment: Lemieux.Environment.local()
      }
    }
  end

  defp run(args, ctx), do: args |> Bash.run(ctx) |> Tool.collect()

  test "captures stdout", %{ctx: ctx} do
    assert {:ok, output} = run(%{"command" => "echo hello"}, ctx)
    assert output =~ "hello"
  end

  test "captures stderr alongside stdout, in order", %{ctx: ctx} do
    assert {:ok, output} = run(%{"command" => "echo out; echo err 1>&2"}, ctx)

    assert output =~ "out"
    assert output =~ "err"
  end

  test "a non-zero exit is a result, not an error", %{ctx: ctx} do
    # The model has to see the failure and decide what to do about it. An
    # {:error, _} here would look to the loop like the tool broke, rather than
    # like the command reported something true.
    assert {:ok, output} = run(%{"command" => "echo nope 1>&2; exit 3"}, ctx)

    assert output =~ "nope"
    assert output =~ "exit status 3"
  end

  test "command facts survive collection without changing the tool outcome", %{ctx: ctx} do
    cases = [
      {{:exit_status, 0}, %{"status" => "exited", "exit_status" => 0}},
      {{:exit_status, 3}, %{"status" => "exited", "exit_status" => 3}},
      {{:timeout, 200}, %{"status" => "timed_out", "timeout_ms" => 200}},
      {{:output_limit, 500}, %{"status" => "output_limit", "max_output_bytes" => 500}}
    ]

    for {event, expected} <- cases do
      env = {LemieuxTest.ScriptedEnvironment, [{:data, "before\n"}, event]}
      context = Map.put(ctx, :environment, env)

      assert {:ok, result} =
               %{"command" => "check"}
               |> Bash.run(context)
               |> Tool.collect_result(fn _ -> :ok end, 1_000)

      assert result.structured_content == expected
      assert result.model_text =~ "before"
    end
  end

  test "a successful command does not shout about its exit status", %{ctx: ctx} do
    assert {:ok, output} = run(%{"command" => "echo fine"}, ctx)

    refute output =~ "exit status"
  end

  test "runs in the session's working directory", %{tmp_dir: tmp_dir, ctx: ctx} do
    File.write!(Path.join(tmp_dir, "marker.txt"), "x")

    assert {:ok, output} = run(%{"command" => "ls"}, ctx)
    assert output =~ "marker.txt"
  end

  test "a command that produces nothing says so, rather than returning blankness", %{ctx: ctx} do
    assert {:ok, output} = run(%{"command" => "true"}, ctx)
    assert output =~ "no output"
  end

  # Both of these are the same failure the moduledoc argues against: output
  # that stops without explanation reads to a model as a command that ran and
  # said nothing. A broken stream reported as `[exit status 1]` is worse than
  # unhelpful — it is indistinguishable from a command that genuinely failed,
  # so the model debugs the command instead of the transport.
  test "a broken output stream is an error, not disguised as an exit status", %{ctx: ctx} do
    events = [{:data, "started\n"}, {:failed, :epipe}]
    ctx = Map.put(ctx, :environment, {LemieuxTest.ScriptedEnvironment, events})

    assert {:error, output} = run(%{"command" => "echo hello"}, ctx)

    assert output =~ "started"
    assert output =~ "epipe"
    refute output =~ "exit status"
  end

  test "a chunk that carried no bytes still leaves the ending stated", %{ctx: ctx} do
    events = [{:data, ""}, {:exit_status, 0}]
    ctx = Map.put(ctx, :environment, {LemieuxTest.ScriptedEnvironment, events})

    assert {:ok, output} = run(%{"command" => "echo hello"}, ctx)

    assert output =~ "no output"
  end

  test "output beyond the cap keeps head and tail with a truncation marker", %{ctx: ctx} do
    assert {:ok, output} = run(%{"command" => "seq 1 200000"}, ctx)

    assert output =~ "cut from the middle by lemieux"
    assert output =~ "1\n"
    assert output =~ "200000"
  end

  test "a command exceeding the timeout is killed and reported", %{ctx: ctx} do
    assert {:ok, output} = run(%{"command" => "sleep 30", "timeout_ms" => 200}, ctx)

    assert output =~ "timed out"
    assert output =~ "200"
  end

  # The deadline covers starting the command, not just running it — see
  # `Lemieux.Environment.Local.ExCmd`. Starting one costs about 350ms at the
  # worst of this suite's own concurrency, so a budget near that measures the
  # scheduler rather than the behaviour under test, which is that output
  # already produced survives the kill.
  test "a timeout keeps the output the command produced before it hung", %{ctx: ctx} do
    assert {:ok, output} =
             run(%{"command" => "echo before; sleep 30", "timeout_ms" => 2_000}, ctx)

    assert output =~ "before"
    assert output =~ "timed out"
  end

  test "invalid bytes in output do not break the transcript", %{ctx: ctx} do
    assert {:ok, output} = run(%{"command" => "printf '\\xff\\xfehi'"}, ctx)

    assert String.valid?(output)
    assert output =~ "hi"
  end

  test "a missing command is an error the model can act on", %{ctx: ctx} do
    assert {:error, message} = run(%{}, ctx)
    assert message =~ "command"
  end

  test "a command and task id together are rejected at execution", %{ctx: ctx} do
    assert {:error, message} =
             run(%{"command" => "echo never", "task_id" => "01INVALID"}, ctx)

    assert message =~ "not both"
  end

  test "the tool describes itself well enough to be called" do
    assert Bash.name() == "bash"

    assert %{
             "type" => "object",
             "properties" => %{"command" => _, "task_id" => _},
             "additionalProperties" => false
           } = Bash.schema()
  end

  test "starts a command in the background and polls it", %{ctx: ctx} do
    ctx = background_context(ctx)

    assert {:ok, started} =
             run(
               %{
                 "command" => "printf first; sleep 0.2; printf second",
                 "background" => true
               },
               ctx
             )

    assert [task_id] = Regex.run(~r/[0-9A-HJKMNP-TV-Z]{26}/, started)

    assert {:ok, polled} = run(%{"task_id" => task_id}, ctx)
    assert polled =~ "Status: running"

    assert {:ok, finished} = run(%{"task_id" => task_id, "wait_ms" => 2_000}, ctx)
    assert finished =~ "Status: exited (0)"
    assert finished =~ "firstsecond"
  end

  test "awaiting a background command can yield while it remains running", %{ctx: ctx} do
    ctx = background_context(ctx)

    assert {:ok, started} =
             run(%{"command" => "sleep 1", "background" => true}, ctx)

    assert [task_id] = Regex.run(~r/[0-9A-HJKMNP-TV-Z]{26}/, started)
    assert {:ok, output} = run(%{"task_id" => task_id, "wait_ms" => 20}, ctx)
    assert output =~ "still running after waiting 20ms"
  end

  describe "a host runner" do
    test "relocates execution while keeping bash's result semantics", %{ctx: ctx} do
      caller = self()

      bash =
        Bash.new(
          runner: fn command, opts ->
            send(caller, {:ran, command, opts})
            {:ok, "container output\n", 7}
          end
        )

      assert Tool.name(bash) == "bash"
      assert {:ok, output} = Tool.invoke(bash, %{"command" => "mix test"}, ctx)
      assert_receive {:ran, "mix test", [cwd: cwd, timeout_ms: 120_000]}
      assert cwd == ctx.cwd
      assert output.model_text == "container output\n\n[exit status 7]"
      assert output.structured_content == %{"status" => "exited", "exit_status" => 7}
    end

    test "reports that an injected runner could not execute", %{ctx: ctx} do
      bash = Bash.new(runner: fn _command, _opts -> {:error, :container_gone} end)

      assert {:error, message} = Tool.invoke(bash, %{"command" => "true"}, ctx)
      assert message =~ "container_gone"
    end

    test "turns an injected runner crash into a tool error", %{ctx: ctx} do
      bash = Bash.new(runner: fn _command, _opts -> raise "runner exploded" end)

      assert {:error, message} = Tool.invoke(bash, %{"command" => "true"}, ctx)
      assert message =~ "runner crashed"
      assert message =~ "runner exploded"
    end

    test "enforces the requested timeout around an injected runner", %{ctx: ctx} do
      bash = Bash.new(runner: fn _command, _opts -> receive do: (:stop -> :ok) end)

      assert {:ok, output} =
               Tool.invoke(bash, %{"command" => "sleep forever", "timeout_ms" => 20}, ctx)

      assert output.model_text =~ "timed out after 20ms"
      assert output.structured_content == %{"status" => "timed_out", "timeout_ms" => 20}
    end

    test "can run an injected runner in the background", %{ctx: ctx} do
      ctx = background_context(ctx)
      bash = Bash.new(runner: fn _command, _opts -> {:ok, "remote output", 4} end)

      assert {:ok, started} =
               Tool.invoke(bash, %{"command" => "remote", "background" => true}, ctx)

      assert [task_id] = Regex.run(~r/[0-9A-HJKMNP-TV-Z]{26}/, to_string(started))

      assert {:ok, finished} =
               Tool.invoke(bash, %{"task_id" => task_id, "wait_ms" => 2_000}, ctx)

      assert to_string(finished) =~ "Status: exited (4)"
      assert to_string(finished) =~ "remote output"
    end
  end

  test "streams output before the command exits", %{ctx: ctx} do
    assert {:stream, stream} = Bash.run(%{"command" => "echo first; sleep 1; echo second"}, ctx)

    assert stream |> Enum.take(1) |> IO.iodata_to_binary() =~ "first"
  end

  describe "nobody is at this terminal" do
    test "commands run with pagers and git prompts turned off", %{ctx: ctx} do
      command =
        ~s(printf '%s|%s|%s|%s' "$PAGER" "$GIT_PAGER" "$GIT_TERMINAL_PROMPT" "$GIT_EDITOR")

      assert {:ok, "cat|cat|0|true"} = run(%{"command" => command}, ctx)
    end

    test "background commands get the same environment", %{ctx: ctx} do
      ctx = background_context(ctx)

      assert {:ok, started} =
               run(
                 %{"command" => ~s(printf %s "$GIT_TERMINAL_PROMPT"), "background" => true},
                 ctx
               )

      [task_id] = Regex.run(~r/[0-9A-HJKMNP-TV-Z]{26}/, started)
      assert {:ok, finished} = run(%{"task_id" => task_id, "wait_ms" => 5_000}, ctx)
      assert finished =~ "Status: exited (0)"
      assert finished =~ ~r/\n0$/
    end
  end

  describe "terminal escape sequences" do
    test "are removed from output, even when a chunk boundary splits one", %{ctx: ctx} do
      events = [
        {:data, "\e[31mred"},
        {:data, "\e[0m \e[3"},
        {:data, "2mgreen\e[0m\e]0;title\a"},
        {:exit_status, 0}
      ]

      ctx = Map.put(ctx, :environment, {LemieuxTest.ScriptedEnvironment, events})
      assert {:ok, "red green"} = run(%{"command" => "colour"}, ctx)
    end

    test "output that was only escape sequences is no output", %{ctx: ctx} do
      events = [{:data, "\e[2K\e[1G"}, {:exit_status, 0}]
      ctx = Map.put(ctx, :environment, {LemieuxTest.ScriptedEnvironment, events})

      assert {:ok, "[the command produced no output]"} = run(%{"command" => "redraw"}, ctx)
    end

    test "are removed from a host runner's captured output", %{ctx: ctx} do
      bash = Bash.new(runner: fn _command, _opts -> {:ok, "\e[1mbold\e[0m\n", 0} end)

      assert {:ok, result} = Tool.invoke(bash, %{"command" => "x"}, ctx)
      assert result.model_text == "bold"
    end
  end

  describe "arguments a provider fills in" do
    test "a null or empty task_id beside a command counts as absent", %{ctx: ctx} do
      assert {:ok, "one"} = run(%{"command" => "printf one", "task_id" => nil}, ctx)
      assert {:ok, "two"} = run(%{"command" => "printf two", "task_id" => ""}, ctx)
    end

    test "a null field alone is still a missing command", %{ctx: ctx} do
      assert {:error, message} = run(%{"command" => nil}, ctx)
      assert message =~ "needs a command"
    end
  end

  test "a background command can be cancelled by the model", %{ctx: ctx} do
    ctx = background_context(ctx)

    assert {:ok, started} = run(%{"command" => "sleep 30", "background" => true}, ctx)
    [task_id] = Regex.run(~r/[0-9A-HJKMNP-TV-Z]{26}/, started)

    assert {:ok, cancelled} = run(%{"task_id" => task_id, "cancel" => true}, ctx)
    assert cancelled =~ "Status: cancelled"

    assert {:error, message} = run(%{"task_id" => "01UNKNOWNTASK", "cancel" => true}, ctx)
    assert message =~ "not found"
  end

  # The session stops a call at `deadline_ms` and reports an error that says
  # nothing about the command (#38): a 180-second host limit turned a
  # `wait_ms: 180000` poll of a running task into a failed call.
  describe "the call's deadline" do
    defmodule RecordingEnvironment do
      @moduledoc false
      @behaviour Lemieux.Environment

      @impl Lemieux.Environment
      def read_file(_state, _cwd, _path), do: {:error, :enoent}

      @impl Lemieux.Environment
      def write_file(_state, _cwd, _path, _contents), do: {:error, :enotsup}

      @impl Lemieux.Environment
      def run(caller, _command, opts) do
        send(caller, {:timeout_ms, opts[:timeout_ms]})
        {:ok, [{:data, "partial\n"}, {:timeout, opts[:timeout_ms]}]}
      end
    end

    setup %{ctx: ctx} do
      %{ctx: Map.merge(ctx, %{environment: {RecordingEnvironment, self()}, deadline_ms: 180_000})}
    end

    test "cuts a longer timeout to end before it, and says why the command stopped", %{
      ctx: ctx
    } do
      assert {:ok, output} = run(%{"command" => "train", "timeout_ms" => 600_000}, ctx)

      assert_received {:timeout_ms, 175_000}
      assert output =~ "partial"
      assert output =~ "timed out after 175000ms"
      assert output =~ "longest one call may run in this session"
      assert output =~ "background"
    end

    test "leaves a timeout that fits alone", %{ctx: ctx} do
      assert {:ok, output} = run(%{"command" => "check", "timeout_ms" => 60_000}, ctx)

      assert_received {:timeout_ms, 60_000}
      assert output =~ "timed out after 60000ms"
      refute output =~ "in this session"
    end

    test "cuts the default timeout when the deadline is shorter than it", %{ctx: ctx} do
      ctx = %{ctx | deadline_ms: 30_000}

      assert {:ok, _output} = run(%{"command" => "check"}, ctx)
      assert_received {:timeout_ms, 27_000}
    end

    test "cuts a host runner's timeout the same way", %{ctx: ctx} do
      bash = Bash.new(runner: fn _command, _opts -> receive do: (:stop -> :ok) end)
      ctx = %{ctx | deadline_ms: 200}

      assert {:ok, output} =
               Tool.invoke(bash, %{"command" => "sleep forever", "timeout_ms" => 600_000}, ctx)

      assert output.model_text =~ "timed out after 180ms"
      assert output.model_text =~ "longest one call may run in this session"
      assert output.structured_content == %{"status" => "timed_out", "timeout_ms" => 180}
    end

    test "a wait that would outlast the call ends as still running, not as an error", %{
      ctx: ctx
    } do
      ctx = ctx |> Map.put(:environment, Lemieux.Environment.local()) |> background_context()
      assert {:ok, started} = run(%{"command" => "sleep 30", "background" => true}, ctx)
      [task_id] = Regex.run(~r/[0-9A-HJKMNP-TV-Z]{26}/, started)

      ctx = %{ctx | deadline_ms: 1_000}
      assert {:ok, output} = run(%{"task_id" => task_id, "wait_ms" => 600_000}, ctx)

      assert output =~ "still running after waiting 900ms"
      assert output =~ "longest one call may wait in this session"
      assert output =~ "Status: running"

      assert {:ok, _cancelled} = run(%{"task_id" => task_id, "cancel" => true}, ctx)
    end
  end

  defp background_context(ctx) do
    runtime = :"lemieux_bash_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    Map.merge(ctx, %{session: self(), supervisor: runtime})
  end
end
