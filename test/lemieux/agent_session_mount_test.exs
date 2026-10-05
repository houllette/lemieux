defmodule Lemieux.AgentSessionMountTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  # Two benchmark workers once raced to mount the convenience runtime: the
  # loser saw the supervisor's name registered before its children existed
  # and failed its attempt with `:noproc` in zero seconds. Eight workers on a
  # fresh runtime name must all complete.
  test "concurrent workers mounting the same fresh runtime all complete", %{tmp_dir: root} do
    supervisor = :"Lemieux.MountRace#{System.unique_integer([:positive])}"

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          cwd = Path.join(root, "w#{index}")
          File.mkdir_p!(cwd)

          Lemieux.Agent.run(
            Lemieux.Agent.Session,
            %{prompt: "Say done.", cwd: cwd, timeout_ms: 10_000},
            provider: Scripted.new([fn _request -> Scripted.complete("done") end]),
            model: "test:model",
            sessions_dir: Path.join(root, "sessions"),
            supervisor: supervisor,
            detach_runtime: true
          )
        end,
        max_concurrency: 8,
        timeout: 20_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{"status" => "completed"}}, &1)),
           inspect(Enum.reject(results, &match?({:ok, _}, &1)))

    assert is_pid(Process.whereis(supervisor))
    Supervisor.stop(supervisor)
  end
end
