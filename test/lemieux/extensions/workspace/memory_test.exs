defmodule Lemieux.Extensions.Workspace.MemoryTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Extensions.Workspace.Init
  alias Lemieux.Extensions.Workspace.Memory

  @moduletag :tmp_dir

  describe "Memory" do
    test "paths are the files discovery reads", %{tmp_dir: tmp_dir} do
      assert Memory.path(:personal, personal_dir: tmp_dir) == Path.join(tmp_dir, "MEMORY.md")
      assert Memory.path(:project, root: tmp_dir) == Path.join(tmp_dir, "MEMORY.md")
    end

    test "append creates the file privately, with a heading and a dated entry", %{
      tmp_dir: tmp_dir
    } do
      personal = Path.join(tmp_dir, "lmx-home")
      path = Memory.path(:personal, personal_dir: personal)

      assert :ok = Memory.append(path, "Prefer mise over asdf here.", today: ~D[2026-09-28])

      assert File.read!(path) == "# Memory\n\n- 2026-09-28: Prefer mise over asdf here.\n"
      assert File.stat!(personal).mode |> Bitwise.band(0o777) == 0o700
    end

    test "entries are appended on their own line, never rewriting what is there", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "MEMORY.md")
      File.write!(path, "My own notes, no trailing newline")

      assert :ok = Memory.append(path, "  first\n  over two lines ", today: ~D[2026-09-28])
      assert :ok = Memory.append(path, "second", today: ~D[2026-09-29])

      assert File.read!(path) ==
               "My own notes, no trailing newline\n" <>
                 "- 2026-09-28: first over two lines\n- 2026-09-29: second\n"
    end

    test "refuses nothing and too much", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "MEMORY.md")

      assert {:error, "nothing to remember"} = Memory.append(path, "   ")
      assert {:error, message} = Memory.append(path, String.duplicate("x", 4_001))
      assert message =~ "4000 bytes"
      refute File.exists?(path)
    end

    test "what is appended is what the next discovery reads", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      path = Memory.path(:project, root: tmp_dir)
      :ok = Memory.append(path, "The flaky test is timing, not logic.")

      assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false)
      assert Discovery.system_prompt(workspace, "base") =~ "The flaky test is timing"
    end
  end

  describe "Init.prompt/1" do
    test "asks for a new AGENTS.md when there is none", %{tmp_dir: tmp_dir} do
      prompt = Init.prompt(tmp_dir)

      assert prompt =~ "Create an AGENTS.md"
      assert prompt =~ "exact commands"
      assert prompt =~ "Do not commit it"
    end

    test "asks to improve an existing AGENTS.md in place", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "old")
      prompt = Init.prompt(tmp_dir)

      assert prompt =~ "Improve this repository's agent instructions (AGENTS.md)"
      assert prompt =~ "editing it in place"
    end

    test "with only a CLAUDE.md, suggests importing AGENTS.md from it", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "old")
      prompt = Init.prompt(tmp_dir) |> String.split() |> Enum.join(" ")

      assert prompt =~ "(CLAUDE.md)"
      assert prompt =~ "@AGENTS.md"
    end
  end
end
