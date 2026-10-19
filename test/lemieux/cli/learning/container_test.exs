defmodule Lemieux.CLI.Learning.ContainerTest do
  use ExUnit.Case, async: false
  alias Lemieux.CLI.Learning.Container
  alias Lemieux.Environment
  @moduletag :tmp_dir
  @moduletag skip: System.get_env("LEMIEUX_TEST_CONTAINERS") != "1"
  @image "python@sha256:2dd78ad5cf13a0b68f5134dc49aa9950203a8cf4b7463431b9f3b398287c5059"

  test "workspace writes work; home, network, root and host credentials are unavailable", %{
    tmp_dir: dir
  } do
    {:ok, env} = Container.new(@image)

    command =
      "python -c 'import os,socket; assert os.getuid()!=0; assert not os.path.exists(\"/Users\"); assert not os.environ.get(\"OPENAI_API_KEY\"); s=socket.socket(); s.settimeout(.1); assert s.connect_ex((\"1.1.1.1\",443))!=0; open(\"result.txt\",\"w\").write(\"confined\")'"

    assert {:ok, events} = Environment.run(env, command, cwd: dir, timeout_ms: 10_000)
    assert {:exit_status, 0} in Enum.to_list(events)
    assert File.read!(Path.join(dir, "result.txt")) == "confined"
  end

  test "caller cancellation removes the running container and descendants", %{tmp_dir: dir} do
    {:ok, env} = Container.new(@image)
    owner = self()

    worker =
      spawn(fn ->
        {:ok, events} =
          Environment.run(env, "echo started; sleep 60 & wait", cwd: dir, timeout_ms: 60_000)

        Enum.each(events, fn
          {:data, data} -> send(owner, {:output, data})
          _ -> :ok
        end)
      end)

    assert_receive {:output, "started\n"}

    {names, 0} =
      System.cmd("docker", [
        "ps",
        "--filter",
        "label=lemieux.learning.qualification=true",
        "--format",
        "{{.Names}}"
      ])

    name = names |> String.trim() |> String.split("\n") |> List.last()
    Process.exit(worker, :kill)
    # A Docker wait supplies an event rather than timing a short sleep. Removal
    # makes inspect fail whether wait observed the stopped container or its removal.
    System.cmd("docker", ["wait", name], stderr_to_stdout: true)
    assert eventually_removed(name, 100)
  end

  defp eventually_removed(_name, 0), do: false

  defp eventually_removed(name, remaining) do
    case System.cmd("docker", ["inspect", name], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(20)
        eventually_removed(name, remaining - 1)

      {_, _} ->
        true
    end
  end
end
