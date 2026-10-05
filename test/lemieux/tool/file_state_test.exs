defmodule Lemieux.Tool.FileStateTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tool.FileState

  setup do
    runtime = :"lemieux_file_state_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{
      context: %{
        cwd: "/work",
        session: self(),
        session_id: "01FILESTATE#{System.unique_integer([:positive])}",
        supervisor: runtime
      }
    }
  end

  test "records what the session has seen, by absolute path", %{context: context} do
    assert FileState.seen(context, "a.txt") == :unseen

    :ok = FileState.record(context, "a.txt", FileState.fingerprint("one"))

    assert FileState.seen(context, "/work/a.txt") == {:ok, FileState.fingerprint("one")}
    assert FileState.seen(context, "./a.txt") == {:ok, FileState.fingerprint("one")}
  end

  test "a context without a session is untracked" do
    assert FileState.seen(%{cwd: "/work"}, "a.txt") == :untracked
    assert FileState.record(%{cwd: "/work"}, "a.txt", "f") == :ok
  end

  test "the record ends with the session", %{context: context} do
    session = spawn(fn -> receive do: (:stop -> :ok) end)
    context = %{context | session: session}

    :ok = FileState.record(context, "a.txt", "f")

    [{pid, _value}] =
      Registry.lookup(background_registry(context), {FileState, context.session_id})

    ref = Process.monitor(pid)

    # A monitor is in place only once the record has received it, and Erlang
    # orders signals per sender, not causally: the session's exit could reach
    # the record before this monitor did, and the monitor then answered
    # :noproc for a record that had ended exactly as it should (9 times in
    # 72,000 rounds under load, none with this call). A call to the record
    # behind the monitor settles it, and shows the record is still there while
    # the session lives.
    assert FileState.seen(context, "a.txt") == {:ok, "f"}

    send(session, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert FileState.seen(context, "a.txt") == :unseen
  end

  defp background_registry(context),
    do: Lemieux.Supervisor.background_registry(context.supervisor)
end
