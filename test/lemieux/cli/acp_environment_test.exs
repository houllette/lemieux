defmodule Lemieux.CLI.ACP.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.ACP.Environment, as: Editor
  alias Lemieux.Environment
  alias Lemieux.Environment.Sandbox

  @moduletag :tmp_dir

  defp bridge(request) do
    %{
      read?: true,
      write?: true,
      request: request,
      notify: fn event -> send(self(), {:editor, event}) end
    }
  end

  test "reads unsaved editor text and writes through the client with a real diff", %{tmp_dir: dir} do
    path = Path.join(dir, "file.txt")
    File.write!(path, "disk")

    environment =
      Editor.wrap(
        Environment.local(),
        bridge(fn
          "fs/read_text_file", %{"path" => ^path} -> {:ok, %{"content" => "unsaved"}}
          "fs/write_text_file", %{"path" => ^path, "content" => "changed"} -> {:ok, %{}}
        end)
      )

    assert {:ok, "unsaved"} = Environment.read_file(environment, dir, "file.txt")
    assert {:ok, :overwritten} = Environment.write_file(environment, dir, "file.txt", "changed")
    assert File.read!(path) == "disk"
    assert_receive {:editor, {:diff, ^path, "unsaved", "changed"}}
  end

  test "a client failure never falls back to a local write", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "file.txt"), "original")

    environment =
      Editor.wrap(
        Environment.local(),
        bridge(fn
          "fs/read_text_file", _params -> {:ok, %{"content" => "original"}}
          "fs/write_text_file", _params -> {:error, :eio}
        end)
      )

    assert {:error, :eio} = Environment.write_file(environment, dir, "file.txt", "changed")
    assert File.read!(Path.join(dir, "file.txt")) == "original"
    refute_receive {:editor, {:diff, _, _, _}}, 20
  end

  test "client access preserves confinement, hidden paths, and read-only sandboxes", %{
    tmp_dir: dir
  } do
    secret = Path.join(dir, "secret")
    File.write!(secret, "hidden")
    bridge = bridge(fn _method, _params -> flunk("a denied path reached the editor") end)
    environment = Editor.wrap(Environment.local(), bridge)
    assert {:error, :outside_worktree} = Environment.read_file(environment, dir, "../outside")
    File.ln_s!(Path.dirname(dir), Path.join(dir, "escape"))
    assert {:error, :outside_worktree} = Environment.read_file(environment, dir, "escape/outside")

    sandbox =
      {Sandbox,
       %Sandbox{
         backend: :seatbelt,
         executable: "unused",
         shell: "unused",
         inner: Environment.local(),
         hidden: [secret],
         read_only: true
       }}

    environment = Editor.wrap(sandbox, bridge)
    assert {:error, :eacces} = Environment.read_file(environment, dir, "secret")
    assert {:error, :erofs} = Environment.write_file(environment, dir, "new", "changed")
  end

  test "unadvertised capabilities and directories retain the host environment", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "file.txt"), "local")

    bridge =
      bridge(fn _method, _params -> flunk("an unadvertised method was called") end)
      |> Map.merge(%{read?: false, write?: false})

    environment = Editor.wrap(Environment.local(), bridge)
    assert {:ok, "local"} = Environment.read_file(environment, dir, "file.txt")
    assert {:ok, [%{name: "file.txt"}]} = Environment.list_dir(environment, dir, ".")
    assert {:ok, :created} = Environment.write_file(environment, dir, "new", "text")
    assert File.read!(Path.join(dir, "new")) == "text"
  end
end
