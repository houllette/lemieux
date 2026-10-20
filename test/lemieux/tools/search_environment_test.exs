defmodule Lemieux.Tools.SearchEnvironmentTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment.Local
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.Glob
  alias Lemieux.Tools.Grep
  alias Lemieux.Tools.Search.Command

  @moduletag :tmp_dir

  # A separate filesystem under /app. The host cwd is only an opaque token;
  # file operations and helper commands resolve in the environment's tree.
  defmodule Remote do
    @behaviour Lemieux.Environment

    def read_file(state, _cwd, path) do
      with {:ok, relative} <- path(path), do: Local.read_file(nil, state.root, relative)
    end

    def list_dir(state, _cwd, path) do
      with {:ok, relative} <- path(path), do: Local.list_dir(nil, state.root, relative)
    end

    def write_file(_state, _cwd, _path, _contents), do: {:error, :read_only}

    def run(state, command, opts) do
      send(state.owner, {:search_command, opts[:cwd], command})

      with {:ok, relative} <- path(opts[:cwd]) do
        if state.fallback do
          {:ok, [{:exit_status, 127}]}
        else
          # Simulate the shell's /app namespace as well as mapping callback cwd.
          command =
            command
            |> String.replace("'/app/", Command.quote_argument(state.root <> "/") <> "'")
            |> String.replace("'/app'", Command.quote_argument(state.root))

          Local.run(nil, command, Keyword.put(opts, :cwd, Path.join(state.root, relative)))
        end
      end
    end

    defp path("/app"), do: {:ok, "."}
    defp path("/app/" <> relative), do: {:ok, relative}
    defp path("/host-workspace"), do: {:ok, "."}

    defp path(path) do
      if Path.type(path) == :relative, do: {:ok, path}, else: {:error, :outside_worktree}
    end
  end

  setup %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, "src/example.ex"), "def example, do: :ok\n")
    %{root: root}
  end

  defp context(root, fallback) do
    %{
      cwd: "/host-workspace",
      environment: {Remote, %{root: root, fallback: fallback, owner: self()}}
    }
  end

  test "absolute environment directories work in glob and grep's walking fallback", %{root: root} do
    ctx = context(root, true)

    assert {:ok, %Result{model_text: glob}} =
             Glob.run(%{"pattern" => "*.ex", "path" => "/app/src"}, ctx)

    assert glob =~ "/app/src/example.ex"

    assert {:ok, %Result{model_text: grep}} =
             Grep.run(%{"pattern" => "def", "path" => "/app/src"}, ctx)

    assert grep =~ "/app/src/example.ex:1:def example"
    assert_receive {:search_command, "/host-workspace", command}
    assert command =~ "cd -- '/app/src' && "
  end

  test "absolute environment files work in grep", %{root: root} do
    assert {:ok, %Result{model_text: text}} =
             Grep.run(
               %{"pattern" => "example", "path" => "/app/src/example.ex"},
               context(root, true)
             )

    assert text =~ "/app/src/example.ex:1:"
  end

  test "helper commands retain the workspace and enter the environment directory", %{
    root: root
  } do
    # Git's file-listing fallback works even on machines without rg.
    assert {_, 0} = System.cmd("git", ["init", "-q"], cd: root)
    ctx = context(root, false)

    assert {:ok, %Result{model_text: text}} =
             Glob.run(%{"pattern" => "*.ex", "path" => "/app/src"}, ctx)

    assert text =~ "/app/src/example.ex"
    assert_receive {:search_command, "/host-workspace", command}
    assert command =~ "cd -- '/app/src' && "
    refute command =~ "/host-workspace"

    if System.find_executable("rg") do
      assert {:ok, %Result{model_text: text, metadata: %{"backend" => "rg"}}} =
               Grep.run(%{"pattern" => "example", "path" => "/app/src"}, ctx)

      assert text =~ "/app/src/example.ex:1:"
    end
  end

  test "environment refusals and relative-path ergonomics are retained", %{root: root} do
    ctx = context(root, true)
    assert {:error, refused} = Glob.run(%{"pattern" => "*", "path" => "/etc"}, ctx)
    assert refused =~ "outside the working directory"
    assert {:error, refused} = Grep.run(%{"pattern" => "def", "path" => "../../etc"}, ctx)
    assert refused =~ "outside the working directory"

    assert {:ok, %Result{model_text: text}} =
             Glob.run(%{"pattern" => "*.ex", "path" => "src"}, ctx)

    assert text =~ "src/example.ex"
  end
end
