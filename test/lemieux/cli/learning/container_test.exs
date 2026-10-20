defmodule Lemieux.CLI.Learning.ContainerTest do
  use ExUnit.Case, async: false
  alias Lemieux.CLI.Learning.Container
  alias Lemieux.CLI.Learning.Leases
  alias Lemieux.CLI.Learning.Repositories
  alias Lemieux.Contract
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
        "--filter",
        "label=lemieux.learning.workspace=" <> Contract.sha256(Path.expand(dir)),
        "--format",
        "{{.Names}}"
      ])

    [name] = names |> String.trim() |> String.split("\n")
    Process.exit(worker, :kill)
    # A Docker wait supplies an event rather than timing a short sleep. Removal
    # makes inspect fail whether wait observed the stopped container or its removal.
    System.cmd("docker", ["wait", name], stderr_to_stdout: true)
    assert eventually_removed(name, 100)
  end

  test "private verification files are mounted only in grader containers", %{tmp_dir: dir} do
    workspace = Path.join(dir, "workspace")
    tests = Path.join(dir, "private")
    File.mkdir_p!(workspace)
    File.mkdir_p!(tests)
    File.write!(Path.join(tests, "private.txt"), "private verifier")
    {:ok, agent} = Container.new(@image, workdir: "/app")

    {:ok, grader} =
      Container.new(@image, workdir: "/app", verification_mounts: [{tests, "/tests"}])

    assert {:ok, events} =
             Environment.run(agent, "test ! -e /tests/private.txt && test \"$PWD\" = /app",
               cwd: workspace,
               timeout_ms: 10_000
             )

    assert {:exit_status, 0} in Enum.to_list(events)

    assert {:ok, events} =
             Environment.run(
               grader,
               "test -r /tests/private.txt && ! touch /tests/modified 2>/dev/null",
               cwd: workspace,
               timeout_ms: 10_000
             )

    assert {:exit_status, 0} in Enum.to_list(events)
    refute File.exists?(Path.join(tests, "modified"))
  end

  test "imported tasks disclose frozen public paths without disclosing private checks", %{
    tmp_dir: dir
  } do
    source = Path.join(dir, "source")
    private = Path.join(dir, "private")
    File.mkdir_p!(source)
    File.mkdir_p!(private)
    File.write!(Path.join(source, "test_public.py"), "public checks")
    File.write!(Path.join(private, "test_secret.py"), "private check material")
    {:ok, source_sha} = Leases.source_digest(source)
    {:ok, private_sha} = Leases.source_digest(private)
    {:ok, {Container, environment}} = Container.new(@image)

    manifest = %{
      "schema_version" => 1,
      "metadata" => %{"exposure" => "developer_exposed"},
      "tasks" => [
        %{
          "id" => "task",
          "cluster" => "repository",
          "phase" => "confirmation",
          "source" => source,
          "source_sha256" => source_sha,
          "image" => environment.image,
          "prompt" => "Repair the project.",
          "public_pytest_args" => ["test_public.py"],
          "immutable_paths" => ["test_public.py"],
          "private_tests" => private,
          "private_tests_sha256" => private_sha
        }
      ]
    }

    path = Path.join(dir, "manifest.json")
    File.write!(path, JSON.encode!(manifest))
    assert {[fixture], _metadata} = Repositories.materialize(path, Path.join(dir, "import"))
    assert fixture.task.prompt =~ "Repair the project."
    assert fixture.task.prompt =~ "byte-for-byte unchanged"
    assert fixture.task.prompt =~ "test_public.py"
    refute fixture.task.prompt =~ "test_secret.py"
    refute fixture.task.prompt =~ "private check material"
    refute fixture.task.prompt =~ private
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
