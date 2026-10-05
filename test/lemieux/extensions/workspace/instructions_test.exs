defmodule Lemieux.Extensions.Workspace.InstructionsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Discovery

  @moduletag :tmp_dir

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp repo(tmp_dir) do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    tmp_dir
  end

  defp prompt(cwd) do
    assert {:ok, workspace} = Discovery.discover(cwd, personal?: false)
    {Discovery.system_prompt(workspace, "base"), workspace}
  end

  describe "CLAUDE.md imports" do
    test "follow @paths after the importing file, and a shared AGENTS.md appears once", %{
      tmp_dir: tmp_dir
    } do
      root = repo(tmp_dir)
      write(root, "AGENTS.md", "shared instruction")
      write(root, "docs/style.md", "style instruction")
      write(root, "CLAUDE.md", "@AGENTS.md\n\nSee @docs/style.md for the house style.")

      {prompt, workspace} = prompt(root)

      assert prompt =~ "style instruction"
      assert prompt =~ "See @docs/style.md for the house style."
      assert length(String.split(prompt, "shared instruction")) == 2, "AGENTS.md is duplicated"

      paths = Enum.map(workspace.instruction_files, &Path.relative_to(elem(&1, 0), root))
      claude = Enum.find_index(paths, &(&1 == "CLAUDE.md"))
      style = Enum.find_index(paths, &(&1 == "docs/style.md"))
      assert claude < style
    end

    test "resolve relative to the importing file and stop at cycles", %{tmp_dir: tmp_dir} do
      root = repo(tmp_dir)
      write(root, "CLAUDE.md", "@docs/a.md")
      write(root, "docs/a.md", "alpha @./b.md")
      write(root, "docs/b.md", "beta @a.md")

      {prompt, _workspace} = prompt(root)
      assert length(String.split(prompt, "alpha")) == 2
      assert length(String.split(prompt, "beta")) == 2
    end

    test "are followed five levels deep and no further, saying so", %{tmp_dir: tmp_dir} do
      root = repo(tmp_dir)
      write(root, "CLAUDE.md", "@l1.md")

      for level <- 1..7 do
        write(root, "l#{level}.md", "level#{level}-marker @l#{level + 1}.md")
      end

      {prompt, workspace} = prompt(root)
      assert prompt =~ "level5-marker"
      refute prompt =~ "level6-marker"
      assert Enum.any?(workspace.diagnostics, &(&1 =~ "deeper than 5 levels"))
    end

    test "leave mentions, addresses and code alone", %{tmp_dir: tmp_dir} do
      root = repo(tmp_dir)
      write(root, "spec.md", "never imported")

      write(root, "CLAUDE.md", """
      Ask @alice, or mail ops@example.com.
      Use `@spec.md` literally.

      ```elixir
      @spec.md
      ```
      """)

      {prompt, workspace} = prompt(root)
      refute prompt =~ "never imported"
      assert workspace.diagnostics == []
    end

    test "only CLAUDE files import; AGENTS.md is read as written", %{tmp_dir: tmp_dir} do
      root = repo(tmp_dir)
      write(root, "extra.md", "extra instruction")
      write(root, "AGENTS.md", "Read @extra.md when relevant.")

      {prompt, _workspace} = prompt(root)
      refute prompt =~ "extra instruction"
    end

    test "refuse targets outside the repository, through symlinks too", %{tmp_dir: tmp_dir} do
      root = repo(Path.join(tmp_dir, "repo"))
      outside = write(tmp_dir, "outside.md", "outside instruction")
      File.ln_s!(outside, Path.join(root, "linked.md"))
      write(root, "CLAUDE.md", "@linked.md and @/etc/hosts")

      {prompt, workspace} = prompt(root)
      refute prompt =~ "outside instruction"
      diagnostics = Enum.join(workspace.diagnostics, "\n")
      assert diagnostics =~ "@linked.md was not followed: it is outside the repository"

      if File.regular?("/etc/hosts"),
        do: assert(diagnostics =~ "@/etc/hosts was not followed: it is outside")
    end

    test "follow a symlink that stays inside the repository", %{tmp_dir: tmp_dir} do
      root = repo(tmp_dir)
      write(root, "docs/shared.md", "shared through a link")
      File.ln_s!(Path.join(root, "docs/shared.md"), Path.join(root, "linked.md"))
      write(root, "CLAUDE.md", "@linked.md")

      {prompt, workspace} = prompt(root)
      assert prompt =~ "shared through a link"
      assert workspace.diagnostics == []
    end
  end

  describe "the size cap" do
    test "cuts an oversized file on a line boundary and says so to both readers", %{
      tmp_dir: tmp_dir
    } do
      root = repo(tmp_dir)
      line = String.duplicate("x", 99) <> "\n"
      huge = "first line\n" <> String.duplicate(line, 400) <> "LAST LINE"
      write(root, "AGENTS.md", huge)

      {prompt, workspace} = prompt(root)

      assert prompt =~ "first line"
      refute prompt =~ "LAST LINE"
      assert prompt =~ "this file is #{byte_size(huge)} bytes"
      assert Enum.any?(workspace.diagnostics, &(&1 =~ "over 32 KiB and was truncated"))

      [{_path, kept}] = workspace.instruction_files
      [body, _notice] = String.split(kept, "\n\n[lmx:", parts: 2)
      assert byte_size(body) <= 32_768
      assert String.ends_with?(body, "x"), "cut in the middle of a line"
    end

    test "leaves a file within the budget untouched", %{tmp_dir: tmp_dir} do
      root = repo(tmp_dir)
      write(root, "AGENTS.md", "small instruction")

      {_prompt, workspace} = prompt(root)
      assert [{_path, "small instruction"}] = workspace.instruction_files
      assert workspace.diagnostics == []
    end
  end
end
