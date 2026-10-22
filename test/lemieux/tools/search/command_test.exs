defmodule Lemieux.Tools.Search.CommandTest do
  use ExUnit.Case, async: true
  alias Lemieux.Environment.Local
  alias Lemieux.Tools.Search.Command
  @moduletag :tmp_dir

  # A relocated environment mounts the workspace named by cwd. Subdirectories
  # belong in its command namespace, rather than replacing that mount root.
  defmodule Relocated do
    @behaviour Lemieux.Environment
    @impl true
    def read_file(_, _, _), do: {:error, :unused}
    @impl true
    def write_file(_, _, _, _), do: {:error, :unused}
    @impl true
    def run(root, command, opts) do
      if opts[:cwd] == root do
        command =
          String.replace(
            command,
            Command.quote_argument("/app/nested"),
            Command.quote_argument(Path.join(root, "nested"))
          )

        Local.run(nil, command, opts)
      else
        {:error, :wrong_workspace_mount}
      end
    end
  end

  test "scoped helpers keep their owned mount root and enter the command directory", %{
    tmp_dir: root
  } do
    nested = Path.join(root, "nested")
    quoted = Path.join(root, "quoted' directory")

    for path <- [nested, quoted] do
      File.mkdir_p!(path)
      File.write!(Path.join(path, "marker.txt"), "owned workspace")
    end

    for directory <- [nested, "/app/nested", quoted] do
      assert {:ok, %{status: 0, output: "owned workspace"}} =
               Command.run({Relocated, root}, directory, "cat marker.txt", workspace_cwd: root)
    end
  end
end
