defmodule Lemieux.Extensions.VerifyEnvironmentTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Verify
  alias Lemieux.Extensions.Verify.Discovery
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Remote do
    @behaviour Lemieux.Environment

    def read_file({owner, files}, cwd, path) do
      send(owner, {:read, cwd, path})

      case Map.fetch(files, path) do
        {:ok, contents} -> {:ok, contents}
        :error -> {:error, :enoent}
      end
    end

    def write_file(_state, _cwd, _path, _contents), do: {:ok, :created}

    def stream_file({owner, _files} = state, cwd, path) do
      with {:ok, contents} <- read_file(state, cwd, path) do
        {:ok,
         Stream.resource(
           fn -> [contents] end,
           fn
             [contents] -> {[contents], []}
             [] -> {:halt, []}
           end,
           fn _ -> send(owner, {:closed, path}) end
         )}
      end
    end

    def run({owner, _files}, command, opts) do
      send(owner, {:check, command, opts[:cwd]})
      {:ok, [{:exit_status, 0}]}
    end
  end

  test "discovery reads the environment instead of unrelated host files", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "mix.exs"), "host project")
    environment = {Remote, {self(), %{"Makefile" => "check:\n\ttrue\n"}}}

    assert {:ok, %{command: "make check", discovered_from: "Makefile"}} =
             Discovery.discover(cwd, environment: environment)

    assert_receive {:read, ^cwd, "Makefile"}
  end

  test "environment package scripts and lockfiles use the existing convention order", %{
    tmp_dir: cwd
  } do
    environment =
      {Remote,
       {self(),
        %{
          "package.json" => ~s({"scripts":{"test":"vitest run"}}),
          "pnpm-lock.yaml" => ""
        }}}

    assert {:ok, %{command: "pnpm test"}} = Discovery.discover(cwd, environment: environment)
  end

  test "absent remote conventions never fall back to the host and explicit commands read nothing",
       %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "Makefile"), "test:\n\ttrue\n")
    environment = {Remote, {self(), %{}}}
    assert :none = Discovery.discover(cwd, environment: environment)
    assert_receive {:read, ^cwd, "Makefile"}

    assert {:ok, %{command: "host-check"}} =
             Discovery.discover(cwd, environment: environment, command: "host-check")
  end

  test "manifest parsing is bounded", %{tmp_dir: cwd} do
    environment =
      {Remote, {self(), %{"Makefile" => String.duplicate("x", 65_537) <> "\ntest:\n"}}}

    assert :none = Discovery.discover(cwd, environment: environment)
    assert_receive {:read, ^cwd, "Makefile"}
    assert_receive {:closed, "Makefile"}
  end

  test "presence probes close their environment stream", %{tmp_dir: cwd} do
    environment = {Remote, {self(), %{"mix.exs" => ""}}}
    assert {:ok, %{command: "mix test"}} = Discovery.discover(cwd, environment: environment)
    assert_receive {:closed, "mix.exs"}
  end

  test "local discovery refuses a convention linked outside the workspace", %{tmp_dir: root} do
    cwd = Path.join(root, "work")
    File.mkdir_p!(cwd)
    outside = Path.join(root, "outside.exs")
    File.write!(outside, "host-only contents")
    File.ln_s!(outside, Path.join(cwd, "mix.exs"))
    assert :none = Discovery.discover(cwd)
  end

  test "a local presence probe does not open a FIFO", %{tmp_dir: cwd} do
    assert {_output, 0} = System.cmd("mkfifo", [Path.join(cwd, "mix.exs")])
    owner = self()
    {:ok, worker} = Task.start_link(fn -> send(owner, {:discovered, Discovery.discover(cwd)}) end)

    try do
      assert_receive {:discovered, :none}
    after
      Process.unlink(worker)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end
  end

  test "a session discovers and checks in its effective environment", %{tmp_dir: root} do
    cwd = Path.join(root, "work")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "mix.exs"), "host project")
    environment = {Remote, {self(), %{"Makefile" => "test:\n\ttrue\n"}}}
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    {:ok, harness} = Harness.assemble(Harness.new(), [{Verify, []}])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(Path.join(root, "sessions")),
        provider:
          Scripted.new([
            Scripted.tool_call("write", "write", %{"path" => "new.txt", "content" => "remote"}),
            Scripted.complete("done")
          ]),
        model: "test:verify",
        cwd: cwd,
        harness: harness,
        environment: environment
      )

    assert {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(session, "edit")
    assert_receive {:read, ^cwd, "Makefile"}
    assert_receive {:check, "make test", ^cwd}

    assert {:ok, %{last: %{"status" => "passed", "discovered_from" => "Makefile"}}} =
             Verify.status(session)
  end
end
