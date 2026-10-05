defmodule Lemieux.Extensions.Workspace.SkillSourcesTest do
  @moduledoc """
  Where skills come from, which copy of a name wins, and what inspection
  can say about the copies that lost. Every root is a temporary directory:
  nothing here reads the real `~/.claude`, `~/.codex`, `~/.agents` or an
  installed Omarchy.
  """
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Containment
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.Extensions.Workspace.SkillTool

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    File.mkdir_p!(home)

    %{
      home: home,
      repo: repo,
      system: Path.join(tmp_dir, "omarchy/default/agents/skills"),
      personal: [
        home: home,
        personal_dir: Path.join(home, ".lmx"),
        claude_personal_dir: Path.join(home, ".claude"),
        codex_personal_dir: Path.join(home, ".codex"),
        agents_personal_dir: Path.join(home, ".agents")
      ]
    }
  end

  test "every root in precedence order, a later root winning a name clash", ctx do
    sub = Path.join(ctx.repo, "apps/web")
    File.mkdir_p!(sub)
    extra = Path.join(ctx.home, "extra")

    # `create-extension` is a bundled skill, so the bundled copy is the
    # lowest of all.
    roots = [
      {:system, ctx.system},
      {:personal, Path.join(ctx.home, ".codex/skills")},
      {:personal, Path.join(ctx.home, ".agents/skills")},
      {:personal, Path.join(ctx.home, ".claude/skills")},
      {:personal, Path.join(ctx.home, ".lmx/skills")},
      {:repository, Path.join(ctx.repo, ".agents/skills")},
      {:repository, Path.join(ctx.repo, ".claude/skills")},
      {:repository, Path.join(sub, ".agents/skills")},
      {:repository, Path.join(sub, ".claude/skills")},
      {:skill_dir, extra}
    ]

    for {_kind, root} <- roots, do: skill(root, "create-extension", "From #{root}.")

    assert {:ok, workspace} =
             Discovery.discover(
               sub,
               [
                 bundled_skills?: true,
                 system_skill_dirs: [ctx.system],
                 skill_dirs: [extra]
               ] ++ ctx.personal
             )

    assert [winner] = Enum.filter(workspace.skills, &(&1.name == "create-extension"))
    assert winner.description == "From #{extra}."
    assert winner.source == {:skill_dir, extra}

    assert [{:bundled, _bundled} | lost] = Enum.map(workspace.shadowed_skills, & &1.source)
    assert lost == Enum.drop(roots, -1)
  end

  test "~/.lmx/skills overrides ~/.claude/skills, and ~/.lmx/commands ~/.claude/commands", ctx do
    skill(Path.join(ctx.home, ".claude/skills"), "review", "Claude's review.")
    skill(Path.join(ctx.home, ".lmx/skills"), "review", "lmx's review.")
    write(Path.join(ctx.home, ".claude/commands"), "ship.md", "Claude's ship.")
    write(Path.join(ctx.home, ".lmx/commands"), "ship.md", "lmx's ship.")

    assert {:ok, workspace} = Discovery.discover(ctx.repo, ctx.personal)

    assert %{description: "lmx's review."} = named(workspace, "review")
    assert %{description: "lmx's ship.", kind: :command} = named(workspace, "ship")
  end

  test "personal?: false reads none of the four personal roots", ctx do
    for dir <- ~w(.codex .agents .claude .lmx),
        do: skill(Path.join([ctx.home, dir, "skills"]), "mine-#{String.trim(dir, ".")}", "Mine.")

    assert {:ok, workspace} = Discovery.discover(ctx.repo, [personal?: true] ++ ctx.personal)
    assert length(workspace.skills) == 4

    assert {:ok, hermetic} = Discovery.discover(ctx.repo, [personal?: false] ++ ctx.personal)
    assert hermetic.skills == []
  end

  test "system roots are read like personal ones: in place, outside the repository", ctx do
    skill(ctx.system, "diagnose-crash", "Diagnose a crash.")

    assert {:ok, workspace} =
             Discovery.discover(ctx.repo, [system_skill_dirs: [ctx.system]] ++ ctx.personal)

    assert %{source: {:system, system}} = named(workspace, "diagnose-crash")
    assert system == ctx.system
    assert Discovery.system_prompt(workspace, "base") =~ "diagnose-crash: Diagnose a crash."

    # Read in place: an update to the system's copy is the next discovery's.
    skill(ctx.system, "diagnose-crash", "Diagnose a crash, revised.")

    assert {:ok, again} =
             Discovery.discover(ctx.repo, [system_skill_dirs: [ctx.system]] ++ ctx.personal)

    assert %{description: "Diagnose a crash, revised."} = named(again, "diagnose-crash")
  end

  describe "a linked skill's directory is where its files really are" do
    test "a linked skill directory", ctx do
      store = skill(ctx.system, "omarchy", "Customize the desktop.")
      write(store, "hyprland.md", "Hyprland notes.")
      link(store, Path.join(ctx.home, ".claude/skills/omarchy"))

      assert {:ok, workspace} = Discovery.discover(ctx.repo, ctx.personal)
      omarchy = named(workspace, "omarchy")

      assert omarchy.path == Path.join(ctx.home, ".claude/skills/omarchy/SKILL.md")
      assert omarchy.real_path == Path.join(Containment.real_path(store), "SKILL.md")
      assert omarchy.root == Containment.real_path(store)
    end

    test "a SKILL.md that is itself a link resolves its files beside the target", ctx do
      store = Path.join(ctx.home, "store/linked")

      write(
        store,
        "SKILL.md",
        "---\nname: linked\ndescription: Linked.\n---\nRead ${CLAUDE_SKILL_DIR}/reference.md."
      )

      write(store, "reference.md", "The real reference.")

      linked_dir = Path.join(ctx.home, ".agents/skills/linked")
      File.mkdir_p!(linked_dir)
      link(Path.join(store, "SKILL.md"), Path.join(linked_dir, "SKILL.md"))
      write(linked_dir, "reference.md", "A decoy beside the link.")

      assert {:ok, workspace} = Discovery.discover(ctx.repo, ctx.personal)
      linked = named(workspace, "linked")
      real_store = Containment.real_path(store)

      assert linked.root == real_store
      assert {:ok, body} = Skill.render(linked)
      assert body =~ "Skill directory: #{real_store}\n"
      assert body =~ "Read #{real_store}/reference.md."

      [tool] = Discovery.host_tools(workspace)

      assert {:ok, reference} =
               SkillTool.run(tool, %{"name" => "linked", "file" => "reference.md"}, %{})

      assert reference =~ "The real reference."
      refute reference =~ "decoy"
    end
  end

  test "two links to one skill are one entry, and the copies it hid are the same file", ctx do
    store = skill(ctx.system, "omarchy", "Customize the desktop.")
    link(store, Path.join(ctx.home, ".claude/skills/omarchy"))
    link(store, Path.join(ctx.home, ".codex/skills/omarchy"))
    skill(Path.join(ctx.repo, ".claude/skills"), "review", "The repository's review.")
    skill(Path.join(ctx.home, ".lmx/skills"), "review", "My review.")

    assert {:ok, workspace} =
             Discovery.discover(ctx.repo, [system_skill_dirs: [ctx.system]] ++ ctx.personal)

    assert ["omarchy", "review"] == Enum.map(workspace.skills, & &1.name)
    omarchy = named(workspace, "omarchy")
    assert omarchy.source == {:personal, Path.join(ctx.home, ".claude/skills")}

    hidden = Enum.filter(workspace.shadowed_skills, &(&1.name == "omarchy"))

    assert Enum.map(hidden, & &1.source) == [
             {:system, ctx.system},
             {:personal, Path.join(ctx.home, ".codex/skills")}
           ]

    assert Enum.all?(hidden, &(&1.real_path == omarchy.real_path))

    # A different file of the same name is overridden, not the same file.
    assert [%{source: {:personal, _lmx}} = mine] =
             Enum.filter(workspace.shadowed_skills, &(&1.name == "review"))

    refute mine.real_path == named(workspace, "review").real_path
    assert Discovery.system_prompt(workspace, "base") |> occurrences("omarchy:") == 1
  end

  test "a skill reached three ways reports its notes once", ctx do
    store = Path.join(ctx.system, "granted")

    write(
      store,
      "SKILL.md",
      "---\nname: granted\ndescription: Granted.\nallowed-tools: Bash\n---\nBody"
    )

    link(store, Path.join(ctx.home, ".claude/skills/granted"))
    link(store, Path.join(ctx.home, ".codex/skills/granted"))

    assert {:ok, workspace} =
             Discovery.discover(ctx.repo, [system_skill_dirs: [ctx.system]] ++ ctx.personal)

    notes = Enum.filter(workspace.diagnostics, &(&1 =~ "allowed-tools is informational"))
    assert length(notes) == 1
    assert workspace.skill_diagnostics == notes
  end

  test "disabled names leave the catalog, the tool and the slash commands", ctx do
    skill(ctx.system, "diagnose-crash", "Diagnose a crash.")
    skill(Path.join(ctx.home, ".claude/skills"), "diagnose-crash", "My copy.")
    skill(Path.join(ctx.home, ".claude/skills"), "keep", "Keep this one.")
    plugin = Path.join(ctx.home, "plugins/kit")
    skill(Path.join(plugin, "skills"), "review", "Plugin review.")

    assert {:ok, workspace} =
             Discovery.discover(
               ctx.repo,
               [
                 system_skill_dirs: [ctx.system],
                 plugin_dirs: [plugin],
                 disabled_skills: ["diagnose-crash", "kit:review"]
               ] ++ ctx.personal
             )

    assert Enum.map(workspace.skills, &Skill.qualified_name/1) == ["keep"]

    assert Enum.map(workspace.disabled_skills, &Skill.qualified_name/1) == [
             "diagnose-crash",
             "kit:review"
           ]

    prompt = Discovery.system_prompt(workspace, "base")
    refute prompt =~ "diagnose-crash"
    refute prompt =~ "kit:review"
    assert [tool] = Discovery.host_tools(workspace)
    assert SkillTool.schema(tool)["properties"]["name"]["enum"] == ["keep"]
    assert Enum.map(Discovery.user_skills(workspace), & &1.name) == ["keep"]

    assert {:error, _unknown} = SkillTool.run(tool, %{"name" => "diagnose-crash"}, %{})
  end

  test "the catalog tells the model how to load a skill's files", ctx do
    skill(Path.join(ctx.repo, ".claude/skills"), "review", "Review.")

    assert {:ok, workspace} = Discovery.discover(ctx.repo, personal?: false)
    prompt = Discovery.system_prompt(workspace, "base")

    assert prompt =~ ~s(adding "file" with its path relative to that directory)
    refute prompt =~ "Resolve relative scripts"
  end

  defp named(workspace, name), do: Enum.find(workspace.skills, &(&1.name == name))

  defp occurrences(text, pattern), do: length(:binary.matches(text, pattern))

  defp skill(root, name, description) do
    directory = Path.join(root, name)
    write(directory, "SKILL.md", "---\nname: #{name}\ndescription: #{description}\n---\nBody")
    directory
  end

  defp write(directory, name, contents) do
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, name), contents)
  end

  defp link(target, path) do
    File.mkdir_p!(Path.dirname(path))
    File.ln_s!(target, path)
  end
end
