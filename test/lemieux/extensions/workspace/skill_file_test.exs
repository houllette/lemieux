defmodule Lemieux.Extensions.Workspace.SkillFileTest do
  @moduledoc """
  The `skill` tool's `"file"`: the files beside a skill, which the `read`
  tool cannot reach for a personal, system or plugin skill, and the paths
  it refuses. Every home directory here is a temporary one.
  """
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Containment
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.Extensions.Workspace.SkillTool

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    store = Path.join(tmp_dir, "omarchy/default/agents/skills/omarchy")

    write(store, "SKILL.md", """
    ---
    name: omarchy
    description: Customize the desktop.
    ---
    Read hyprland.md before starting.
    """)

    write(store, "hyprland.md", "Bind keys in bindings.lua.")
    write(store, "references/api.md", "The API.")
    write(store, ".hidden", "not listed")
    write(tmp_dir, "omarchy/default/agents/skills/secret.md", "Outside the skill.")
    File.ln_s!("../secret.md", Path.join(store, "escape.md"))

    {:ok, skill} = Skill.read(Path.join(store, "SKILL.md"))

    %{
      home: home,
      store: store,
      skill: skill,
      tool: SkillTool.new([skill], home: home)
    }
  end

  test "the loaded skill lists its files and how to load one", ctx do
    assert {:ok, body} = SkillTool.run(ctx.tool, %{"name" => "omarchy"}, %{})

    assert body =~
             ~s(Files in the skill directory, loaded with the skill tool as {"name": "omarchy", "file": "PATH"}:)

    assert body =~ "- hyprland.md\n- references/api.md\n"
    refute body =~ "SKILL.md"
    refute body =~ ".hidden"
    # A link out of the directory is not offered, since it would be refused.
    refute body =~ "escape.md"
  end

  test "loads a file beside the skill, and one a level down", ctx do
    assert {:ok, text} = load(ctx, "hyprland.md")
    assert text =~ "File: hyprland.md"
    assert text =~ "Bind keys in bindings.lua."

    assert {:ok, nested} = load(ctx, "references/api.md")
    assert nested =~ "The API."
  end

  test "arguments are substituted into the body only, never into a file", ctx do
    write(ctx.store, "template.md", "Keep $ARGUMENTS as written.")

    assert {:ok, text} =
             SkillTool.run(
               ctx.tool,
               %{"name" => "omarchy", "file" => "template.md", "arguments" => "x"},
               %{}
             )

    assert text =~ "Keep $ARGUMENTS as written."
  end

  test "refuses a path out of the directory, spelt with .. or through a link", ctx do
    assert {:error, dots} = load(ctx, "../secret.md")
    assert dots =~ "outside the skill's directory"

    assert {:error, linked} = load(ctx, "escape.md")
    assert linked =~ "outside the skill's directory"

    for {:ok, text} <- [load(ctx, "../secret.md"), load(ctx, "escape.md")],
        do: flunk("loaded #{text}")
  end

  test "refuses an absolute path, even to a file inside the skill", ctx do
    assert {:error, message} = load(ctx, Path.join(ctx.store, "hyprland.md"))
    assert message =~ "not relative"
  end

  test "a missing file names the files there are", ctx do
    assert {:error, message} = load(ctx, "hyprlnd.md")
    assert message =~ "has no file hyprlnd.md"
    assert message =~ "hyprland.md"
  end

  test "never loads a credential location, even inside the skill's directory", ctx do
    # A skill whose directory is the home directory itself.
    write(ctx.home, "SKILL.md", "---\nname: dotfiles\ndescription: Dotfiles.\n---\nBody")
    write(ctx.home, ".ssh/id_ed25519", "PRIVATE KEY")
    write(ctx.home, "notes.md", "Ordinary notes.")
    {:ok, dotfiles} = Skill.read(Path.join(ctx.home, "SKILL.md"))
    tool = SkillTool.new([dotfiles], home: ctx.home)

    assert {:error, message} =
             SkillTool.run(tool, %{"name" => "dotfiles", "file" => ".ssh/id_ed25519"}, %{})

    assert message =~ "~/.ssh, where credentials live"
    refute message =~ "PRIVATE KEY"

    assert {:ok, notes} = SkillTool.run(tool, %{"name" => "dotfiles", "file" => "notes.md"}, %{})
    assert notes =~ "Ordinary notes."
  end

  test "a skill kept in ~/.lmx/skills loads its own files", ctx do
    directory = Path.join(ctx.home, ".lmx/skills/notes")
    write(directory, "SKILL.md", "---\nname: notes\ndescription: Notes.\n---\nBody")
    write(directory, "guide.md", "My guide.")
    write(ctx.home, ".lmx/config.json", ~s({"providers": {}}))
    File.ln_s!("../../config.json", Path.join(directory, "config.md"))
    {:ok, notes} = Skill.read(Path.join(directory, "SKILL.md"))
    tool = SkillTool.new([notes], home: ctx.home)

    assert {:ok, guide} = SkillTool.run(tool, %{"name" => "notes", "file" => "guide.md"}, %{})
    assert guide =~ "My guide."

    assert {:error, _outside} =
             SkillTool.run(tool, %{"name" => "notes", "file" => "config.md"}, %{})
  end

  test "refuses a binary file and says to run a script with bash", ctx do
    write(ctx.store, "tool.bin", <<0x7F, "ELF", 0, 1, 2>>)

    assert {:error, message} = load(ctx, "tool.bin")
    assert message =~ "not text"
    assert message =~ "run it with bash"
    assert message =~ Path.join(Containment.real_path(ctx.store), "tool.bin")
  end

  test "a long file comes in parts that name the file again", ctx do
    write(ctx.store, "long.md", Enum.map_join(1..400, "\n", &"line #{&1} of the reference"))
    context = %{tool_output_bytes: 5_000}

    assert {:ok, first} =
             SkillTool.run(ctx.tool, %{"name" => "omarchy", "file" => "long.md"}, context)

    assert byte_size(first) <= 5_000
    assert first =~ "line 1 of the reference"
    assert first =~ ~s(Call skill again with "part": 2 and the same "file")

    pages =
      Stream.iterate(1, &(&1 + 1))
      |> Enum.reduce_while([], fn number, pages ->
        {:ok, page} =
          SkillTool.run(
            ctx.tool,
            %{"name" => "omarchy", "file" => "long.md", "part" => number},
            context
          )

        if page =~ "the end.]", do: {:halt, [page | pages]}, else: {:cont, [page | pages]}
      end)

    assert hd(pages) =~ "line 400 of the reference"
    assert hd(pages) =~ "[Skill omarchy file long.md: part #{length(pages)} of"
  end

  test "a file over 1 MiB is refused", ctx do
    write(ctx.store, "huge.md", String.duplicate("x", 1_048_577))
    assert {:error, message} = load(ctx, "huge.md")
    assert message =~ "1048577 bytes"
  end

  test "a plugin's skill may load any file in its plugin, and nothing outside it", %{
    tmp_dir: tmp_dir
  } do
    plugin = Path.join(tmp_dir, "plugins/kit")
    write(plugin, "skills/review/SKILL.md", "---\nname: review\ndescription: R.\n---\nBody")
    write(plugin, "shared/checklist.md", "The shared checklist.")
    write(tmp_dir, "plugins/outside.md", "Not the plugin's.")

    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    {:ok, workspace} = Discovery.discover(repo, personal?: false, plugin_dirs: [plugin])
    [tool] = Discovery.host_tools(workspace)
    load = &SkillTool.run(tool, %{"name" => "kit:review", "file" => &1}, %{})

    assert {:ok, checklist} = load.("../../shared/checklist.md")
    assert checklist =~ "The shared checklist."

    assert {:error, message} = load.("../../../outside.md")
    assert message =~ "outside the skill's plugin"
  end

  test "a legacy command has no files of its own", %{tmp_dir: tmp_dir} do
    write(tmp_dir, "commands/ship.md", "Ship it.")
    write(tmp_dir, "commands/other.md", "Another command.")
    {:ok, command} = Skill.read_command(Path.join(tmp_dir, "commands/ship.md"))
    tool = SkillTool.new([command])

    assert {:ok, body} = SkillTool.run(tool, %{"name" => "ship"}, %{})
    refute body =~ "other.md"

    assert {:error, message} =
             SkillTool.run(tool, %{"name" => "ship", "file" => "other.md"}, %{})

    assert message =~ "no files of its own"
  end

  describe "a repository's skill" do
    setup %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))
      kit = Path.join(repo, ".claude/skills/kit")
      write(kit, "SKILL.md", "---\nname: kit\ndescription: Kit.\n---\nBody")
      write(kit, "guide.md", "Repository guide.")
      write(tmp_dir, "elsewhere/kit/guide.md", "Outside the repository.")

      {:ok, workspace} = Discovery.discover(repo, personal?: false, home: tmp_dir)
      [tool] = Discovery.host_tools(workspace)
      %{kit: kit, repo_tool: tool, elsewhere: Path.join(tmp_dir, "elsewhere/kit")}
    end

    test "loads its files from inside the repository", ctx do
      assert {:ok, guide} =
               SkillTool.run(ctx.repo_tool, %{"name" => "kit", "file" => "guide.md"}, %{})

      assert guide =~ "Repository guide."
    end

    test "is checked again when a file is loaded", ctx do
      # The session's own tools replaced the skill's directory with a link
      # out of the repository after it was discovered.
      File.rm_rf!(ctx.kit)
      File.ln_s!(ctx.elsewhere, ctx.kit)

      assert {:error, message} =
               SkillTool.run(ctx.repo_tool, %{"name" => "kit", "file" => "guide.md"}, %{})

      refute message =~ "Outside the repository."
    end

    test "a file outside the repository's scope is refused by that check too", ctx do
      [skill] = Map.values(ctx.repo_tool.skills)
      other = Containment.scope(ctx.elsewhere, ctx.elsewhere)

      assert {:error, message} = Skill.file(%{skill | within: other}, "guide.md")
      assert message =~ "outside the repository"
    end
  end

  defp load(ctx, file), do: SkillTool.run(ctx.tool, %{"name" => "omarchy", "file" => file}, %{})

  defp write(directory, name, contents) do
    path = Path.join(directory, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
