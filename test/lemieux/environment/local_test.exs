defmodule Lemieux.Environment.LocalTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Local.ExCmd
  alias LemieuxTest.Shell

  @moduletag :tmp_dir

  test "does not read command output before the stream consumer asks for it", %{tmp_dir: tmp_dir} do
    assert ExCmd.available?()
    {:message_queue_len, before_run} = Process.info(self(), :message_queue_len)

    assert {:ok, events} =
             Local.run(nil, "head -c 4000000 /dev/zero",
               cwd: tmp_dir,
               timeout_ms: 2_000
             )

    refute_receive {_demand_ref, {:data, _bytes}}, 100
    {:message_queue_len, before_demand} = Process.info(self(), :message_queue_len)

    assert before_demand - before_run < 10
    assert [{:data, data}] = Enum.take(events, 1)
    assert byte_size(data) > 0
  end

  test "stops a demand-driven command at the environment output cap", %{tmp_dir: tmp_dir} do
    assert {:ok, events} =
             Local.run(nil, "head -c 8100000 /dev/zero",
               cwd: tmp_dir,
               # Generous on purpose: the cap is what this asserts stops the
               # command, so a deadline close enough to expire first turns a
               # failure here into a report about the machine. Eight megabytes
               # through a demand-driven pipe took longer than two seconds when
               # the suite was busy, and the test then read as the cap not
               # working.
               timeout_ms: 30_000
             )

    events = Enum.to_list(events)

    assert List.last(events) == {:output_limit, 8_000_000}

    assert events
           |> Enum.flat_map(fn
             {:data, data} -> [byte_size(data)]
             _terminal -> []
           end)
           |> Enum.sum() <= 8_000_000
  end

  # The deadline is struck before the command exists, so what the command
  # actually gets to run for is the timeout less however long starting it took
  # — and starting one has a long tail: 11ms at the median across twenty-five
  # runs of this suite, 727ms at the worst, and worse again beside another
  # project's suite on the same machine. At a second, that tail ate the whole
  # budget and the shell was stopped before it could write its pid down, which
  # reads here as a broken teardown rather than as a busy machine.
  #
  # Generous on purpose, then, in the same way and for the same reason as the
  # output cap above. The command still has to be killed to pass; it is only
  # given room to start first.
  #
  # Process-group teardown needs a new session for the command: `setsid` on
  # Linux, `perl`'s `POSIX::setsid` on macOS, which ships perl but not setsid.
  # Where neither exists ExCmd can only stop the direct shell, and demanding
  # descendant cleanup would assert a guarantee the runtime does not make.
  unless ExCmd.process_groups?() do
    @tag skip: "requires setsid or perl for process-group isolation"
  end

  test "a timeout stops the shell and its child process", %{tmp_dir: tmp_dir} do
    shell_pid_file = Path.join(tmp_dir, "shell.pid")
    child_pid_file = Path.join(tmp_dir, "child.pid")
    timeout_ms = 5_000

    assert {:ok, events} =
             Local.run(
               nil,
               "echo $$ > #{Shell.quoted(shell_pid_file)}; sleep 30 & " <>
                 "echo $! > #{Shell.quoted(child_pid_file)}; wait",
               cwd: tmp_dir,
               timeout_ms: timeout_ms
             )

    assert List.last(Enum.to_list(events)) == {:timeout, timeout_ms}
    shell_pid = shell_pid_file |> File.read!() |> String.trim()
    child_pid = child_pid_file |> File.read!() |> String.trim()

    assert wait_until_not_running(shell_pid) == :ok
    assert wait_until_not_running(child_pid) == :ok
  end

  # pidfd/kqueue reports exit even before the OS reaps a zombie. Waiting on
  # that event avoids repeatedly spawning ps and sleeping between probes.
  defp wait_until_not_running(pid) do
    fixture = Path.expand("../../fixtures/wait_process.py", __DIR__)

    case System.cmd("python3", [fixture, pid], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, output}
    end
  end

  # ExCmd offers input to a command that never asked for it, and when that
  # command has already exited the write fails and takes the helper Port down
  # with `:epipe` — which arrives as the *exit status* of a command that ran
  # and succeeded. Closing the pipe nothing writes to removes the cause. The
  # visible half is here: a command that reads stdin now sees end-of-input
  # instead of waiting for a deadline that has nothing to do with it.
  test "a command that reads standard input is told there is none", %{tmp_dir: tmp_dir} do
    assert {:ok, events} = Local.run(nil, "cat", cwd: tmp_dir, timeout_ms: 10_000)
    assert Enum.to_list(events) == [{:exit_status, 0}]
  end

  # The owner is the only process that knows the command's process group, so a
  # caller that kills it for being slow strands exactly the children it was
  # trying to stop. That is what happened: a deadline expired while ExCmd was
  # still opening its helper, the stop went into a mailbox the owner could not
  # read for another 493ms, and the kill landed six milliseconds into the
  # teardown — after the group had been resolved and before it was signalled.
  #
  # These two pin the rule that came out of it. The grace is for an owner that
  # has stopped answering, and being slow is not the same thing.
  test "an owner that is still working is not killed for being slow" do
    caller = self()

    {owner, monitor_ref} =
      spawn_monitor(fn ->
        assert_receive :local_command_stop, 5_000

        # The whole stop exceeds the grace, but every progress interval is
        # comfortably shorter. Leave enough scheduling margin for a busy CI
        # runner without weakening the requirement that progress resets grace.
        Enum.each(1..5, fn _step ->
          # This test exercises the real grace timer, so progress is driven
          # by explicit timer events rather than a sleeping worker.
          ref = make_ref()
          Process.send_after(self(), {:progress, ref}, 250)
          assert_receive {:progress, ^ref}
          send(caller, {:local_command_stopping, self()})
        end)

        send(caller, {:owner_finished, self()})
      end)

    assert ExCmd.stop(owner, monitor_ref, 1_000) == :stopped
    assert_receive {:owner_finished, ^owner}
    refute_received {:local_command_stopping, ^owner}
  end

  test "an owner that has stopped answering is killed" do
    {owner, monitor_ref} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)

    assert ExCmd.stop(owner, monitor_ref, 60) == :killed
    refute Process.alive?(owner)
  end

  describe "what commands inherit" do
    setup do
      name = "LEMIEUX_LOCAL_TEST_#{System.unique_integer([:positive])}_TOKEN"
      System.put_env(name, "secret-value")
      on_exit(fn -> System.delete_env(name) end)
      %{name: name}
    end

    test "a scrubbing environment withholds credential-shaped variables", %{
      tmp_dir: tmp_dir,
      name: name
    } do
      {Local, state} = Local.new(credentials: {:scrub, []})

      assert output(
               Local.run(state, ~s(printf %s "${#{name}-unset}"),
                 cwd: tmp_dir,
                 timeout_ms: 10_000
               )
             ) ==
               "unset"

      assert output(
               Local.run(nil, ~s(printf %s "${#{name}-unset}"), cwd: tmp_dir, timeout_ms: 10_000)
             ) ==
               "secret-value"
    end

    test "an allow entry keeps a variable the policy would withhold", %{
      tmp_dir: tmp_dir,
      name: name
    } do
      {Local, state} = Local.new(credentials: {:scrub, [name]})

      assert output(Local.run(state, ~s(printf %s "$#{name}"), cwd: tmp_dir, timeout_ms: 10_000)) ==
               "secret-value"
    end

    test "a variable the caller sets explicitly is kept, and false unsets", %{
      tmp_dir: tmp_dir,
      name: name
    } do
      {Local, state} = Local.new(credentials: true)

      assert output(
               Local.run(state, ~s(printf %s "$#{name}"),
                 cwd: tmp_dir,
                 timeout_ms: 10_000,
                 env: [{name, "given"}]
               )
             ) == "given"

      assert output(
               Local.run(nil, ~s(printf %s "${#{name}-unset}"),
                 cwd: tmp_dir,
                 timeout_ms: 10_000,
                 env: [{name, false}]
               )
             ) == "unset"
    end

    test "the environment reports its policy" do
      assert Lemieux.Environment.credentials(Local) == :inherit

      assert Lemieux.Environment.credentials(Local.new(credentials: {:scrub, ["X"]})) ==
               {:scrub, ["X"]}

      assert_raise ArgumentError, fn -> Local.new(credentials: :everything) end
    end
  end

  describe "paths" do
    test "an absolute path inside the working directory is accepted", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "abs.txt"), "inside")

      assert Local.read_file(nil, tmp_dir, Path.join(tmp_dir, "abs.txt")) == {:ok, "inside"}
      assert {:ok, [%{name: "abs.txt"}]} = Local.list_dir(nil, tmp_dir, tmp_dir)
    end

    test "an absolute path outside it is still refused", %{tmp_dir: tmp_dir} do
      sibling = tmp_dir <> "-sibling"
      File.mkdir_p!(sibling)
      File.write!(Path.join(sibling, "x.txt"), "outside")

      assert Local.read_file(nil, tmp_dir, Path.join(sibling, "x.txt")) ==
               {:error, :outside_worktree}

      assert Local.read_file(nil, tmp_dir, Path.join(tmp_dir, "../x")) ==
               {:error, :outside_worktree}
    end

    test "a file streams in bounded chunks", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "big.txt"), String.duplicate("x", 200_000))

      assert {:ok, chunks} = Local.stream_file(nil, tmp_dir, "big.txt")
      chunks = Enum.to_list(chunks)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(byte_size(&1) <= 65_536))
      assert IO.iodata_length(chunks) == 200_000
    end

    test "streaming says what is not a file", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "dir"))

      assert Local.stream_file(nil, tmp_dir, "dir") == {:error, :eisdir}
      assert Local.stream_file(nil, tmp_dir, "missing") == {:error, :enoent}
      assert Local.stream_file(nil, tmp_dir, "../x") == {:error, :outside_worktree}
    end
  end

  test "a caller that bounds its own memory can lift the output cap", %{tmp_dir: tmp_dir} do
    assert {:ok, events} =
             Local.run(nil, "head -c 8100000 /dev/zero",
               cwd: tmp_dir,
               timeout_ms: 30_000,
               max_output_bytes: :infinity
             )

    assert List.last(Enum.to_list(events)) == {:exit_status, 0}
  end

  defp output({:ok, events}) do
    events
    |> Enum.flat_map(fn
      {:data, data} -> [data]
      _other -> []
    end)
    |> IO.iodata_to_binary()
  end
end
