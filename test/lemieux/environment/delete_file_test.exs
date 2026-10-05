defmodule Lemieux.Environment.DeleteFileTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Tools.FileOps

  # An environment written before `delete_file/3` existed: commands only. It
  # records what it was asked to run, so the fallback is observable.
  defmodule CommandsOnly do
    @behaviour Lemieux.Environment

    @impl true
    def read_file(_state, cwd, path), do: Local.read_file(nil, cwd, path)

    @impl true
    def write_file(_state, cwd, path, contents), do: Local.write_file(nil, cwd, path, contents)

    @impl true
    def run(owner, command, opts) do
      send(owner, {:ran, command})
      Local.run(nil, command, opts)
    end
  end

  @moduletag :tmp_dir

  describe "Local.delete_file/3" do
    test "removes a file inside the working directory", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "gone.txt"), "x")

      assert :ok = Environment.delete_file(Local, cwd, "gone.txt")
      refute File.exists?(Path.join(cwd, "gone.txt"))
    end

    test "an absent file is already deleted", %{tmp_dir: cwd} do
      assert :ok = Environment.delete_file(Local, cwd, "never-there.txt")
    end

    test "refuses a path outside the working directory", %{tmp_dir: cwd} do
      outside = Path.join(Path.dirname(cwd), "outside-#{System.unique_integer([:positive])}")
      File.write!(outside, "keep")
      on_exit(fn -> File.rm(outside) end)

      assert {:error, :outside_worktree} = Environment.delete_file(Local, cwd, outside)
      assert File.read!(outside) == "keep"
    end

    test "a symbolic link is removed as a link, its target left alone", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "README"), "keep")
      File.ln_s!("README", Path.join(cwd, "link"))
      outside = Path.join(Path.dirname(cwd), "target-#{System.unique_integer([:positive])}")
      File.write!(outside, "keep too")
      on_exit(fn -> File.rm(outside) end)
      File.ln_s!(outside, Path.join(cwd, "away"))

      assert :ok = Environment.delete_file(Local, cwd, "link")
      assert :ok = Environment.delete_file(Local, cwd, "away")

      assert {:error, :enoent} = File.lstat(Path.join(cwd, "link"))
      assert {:error, :enoent} = File.lstat(Path.join(cwd, "away"))
      assert File.read!(Path.join(cwd, "README")) == "keep"
      assert File.read!(outside) == "keep too"
    end

    test "refuses a directory and the working directory itself", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join(cwd, "dir"))

      assert {:error, :eisdir} = Environment.delete_file(Local, cwd, "dir")
      assert {:error, :eisdir} = Environment.delete_file(Local, cwd, ".")
      assert File.dir?(Path.join(cwd, "dir"))
    end
  end

  describe "FileOps.delete/3" do
    test "deletes through an environment that implements delete_file/3", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "a.txt"), "x")

      assert :ok = FileOps.delete(Local, cwd, "a.txt")
      refute File.exists?(Path.join(cwd, "a.txt"))
    end

    test "falls back to rm through an environment without delete_file/3", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "b.txt"), "x")

      assert {:error, :unsupported} =
               Environment.delete_file({CommandsOnly, self()}, cwd, "b.txt")

      assert :ok = FileOps.delete({CommandsOnly, self()}, cwd, "b.txt")
      assert_received {:ran, "rm -f -- " <> _path}
      refute File.exists?(Path.join(cwd, "b.txt"))
    end
  end

  test "a sandbox deletes through the environment it wraps", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "c.txt"), "x")
    sandbox = {Sandbox, struct(Sandbox, inner: Local)}

    assert :ok = Environment.delete_file(sandbox, cwd, "c.txt")
    refute File.exists?(Path.join(cwd, "c.txt"))
    assert {:error, :outside_worktree} = Environment.delete_file(sandbox, cwd, "/etc/hosts")
  end
end
