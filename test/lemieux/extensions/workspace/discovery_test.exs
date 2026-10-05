defmodule Lemieux.Extensions.Workspace.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Extensions.Workspace.SkillTool

  @moduletag :tmp_dir

  test "loads applicable AGENTS.md files broadest to nearest", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    write(tmp_dir, "AGENTS.md", "root instruction")
    write(tmp_dir, "apps/AGENTS.md", "near instruction")
    cwd = Path.join(tmp_dir, "apps/service")
    File.mkdir_p!(cwd)

    assert {:ok, workspace} = Discovery.discover(cwd, personal?: false)
    prompt = Discovery.system_prompt(workspace, "base prompt")

    assert prompt =~ "base prompt"
    assert prompt =~ "root instruction"
    assert prompt =~ "near instruction"
    assert position(prompt, "root instruction") < position(prompt, "near instruction")
    assert prompt =~ "user's explicit request overrides repository"
  end

  test "AGENTS.override.md replaces AGENTS.md at the same scope", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    write(tmp_dir, "AGENTS.md", "superseded instruction")
    write(tmp_dir, "AGENTS.override.md", "override instruction")

    assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false)
    prompt = Discovery.system_prompt(workspace, "base")

    assert prompt =~ "override instruction"
    refute prompt =~ "superseded instruction"
  end

  test "a directory outside git is its own workspace, not the filesystem root" do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("lemieux-workspace-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    cwd = Path.join(tmp_dir, "plain")
    File.mkdir_p!(cwd)
    write(tmp_dir, "AGENTS.md", "parent must not leak in")
    write(cwd, "AGENTS.md", "plain workspace instruction")

    assert {:ok, workspace} = Discovery.discover(cwd, personal?: false)
    assert workspace.root == Path.expand(cwd)

    prompt = Discovery.system_prompt(workspace, "base")
    assert prompt =~ "plain workspace instruction"
    refute prompt =~ "parent must not leak in"
  end

  test "advertises skill metadata but leaves the body for progressive disclosure", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))

    write(
      tmp_dir,
      ".agents/skills/review/SKILL.md",
      """
      ---
      name: review
      description: Review changes when asked for code review.
      ---
      DO NOT LOAD THIS BODY AT STARTUP
      """
    )

    assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false)
    prompt = Discovery.system_prompt(workspace, "base")

    assert prompt =~ "review: Review changes"
    refute prompt =~ ".agents/skills/review/SKILL.md"
    assert prompt =~ "call the `skill` tool with its qualified name before acting"
    refute prompt =~ "DO NOT LOAD THIS BODY AT STARTUP"

    assert [tool] = Discovery.host_tools(workspace)
    assert SkillTool.schema(tool)["properties"]["name"]["enum"] == ["review"]
    refute SkillTool.description(tool) =~ "review"

    assert {:ok, body} = SkillTool.run(tool, %{"name" => "review"}, %{})
    assert body =~ "Skill directory: #{Path.join(tmp_dir, ".agents/skills/review")}"
    assert body =~ "DO NOT LOAD THIS BODY AT STARTUP"
  end

  test "loads explicitly selected local marketplace skills", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))

    write(
      tmp_dir,
      "market/plugins/quality/skills/review/SKILL.md",
      "---\nname: review\ndescription: Review carefully.\n---\nbody"
    )

    write(
      tmp_dir,
      "market/.claude-plugin/marketplace.json",
      JSON.encode!(%{
        "name" => "team",
        "plugins" => [%{"name" => "quality", "source" => "./plugins/quality"}]
      })
    )

    assert {:ok, workspace} =
             Discovery.discover(tmp_dir,
               personal?: false,
               marketplaces: [Path.join(tmp_dir, "market")],
               plugins: ["quality@team"]
             )

    assert Discovery.system_prompt(workspace, "base") =~ "quality:review: Review carefully."
  end

  test "the TUI profile layers persona, compatible instructions, and memory", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    write(tmp_dir, "SOUL.md", "Be calm and exact.")
    write(tmp_dir, "MEMORY.md", "The maintainer prefers small commits.")
    write(tmp_dir, "CLAUDE.md", "Use the compatibility instructions.")
    write(tmp_dir, "AGENTS.md", "Use the portable instructions.")
    write(tmp_dir, "apps/CLAUDE.md", "This app uses Finch.")
    cwd = Path.join(tmp_dir, "apps/service")
    File.mkdir_p!(cwd)

    assert {:ok, workspace} = Discovery.discover(cwd, personal?: false)
    prompt = Discovery.system_prompt(workspace, "base")

    assert prompt =~ "## Agent persona"
    assert prompt =~ "Be calm and exact."
    assert prompt =~ "## Durable memory"
    assert prompt =~ "maintainer prefers small commits"
    assert prompt =~ "CLAUDE.md"
    assert prompt =~ "This app uses Finch."

    assert position(prompt, "compatibility instructions") <
             position(prompt, "portable instructions")
  end

  test "personal skills are usable outside the worktree through the allowlisted skill tool", %{
    tmp_dir: tmp_dir
  } do
    workspace_root = Path.join(tmp_dir, "workspace")
    personal_root = Path.join(tmp_dir, "personal")
    File.mkdir_p!(Path.join(workspace_root, ".git"))

    write(
      personal_root,
      "skills/review/SKILL.md",
      "---\nname: review\ndescription: Review a change.\n---\nReview $ARGUMENTS carefully."
    )

    assert {:ok, workspace} =
             Discovery.discover(workspace_root,
               personal_dir: personal_root,
               claude_personal_dir: Path.join(tmp_dir, "no-claude"),
               codex_personal_dir: Path.join(tmp_dir, "no-codex"),
               agents_personal_dir: Path.join(tmp_dir, "no-agents")
             )

    assert [tool] = Discovery.host_tools(workspace)
    assert %SkillTool{} = tool

    assert {:ok, body} =
             SkillTool.run(tool, %{"name" => "review", "arguments" => "lib/example.ex"}, %{})

    assert body =~ "Review lib/example.ex carefully."
  end

  test "loads personal persona, memory, and compatible instructions", %{tmp_dir: tmp_dir} do
    workspace_root = Path.join(tmp_dir, "workspace")
    lmx_root = Path.join(tmp_dir, "lmx")
    claude_root = Path.join(tmp_dir, "claude")
    codex_root = Path.join(tmp_dir, "codex")
    File.mkdir_p!(Path.join(workspace_root, ".git"))
    write(lmx_root, "SOUL.md", "Personal temperament")
    write(lmx_root, "MEMORY.md", "Personal durable fact")
    write(lmx_root, "AGENTS.md", "Personal portable instruction")
    write(claude_root, "CLAUDE.md", "Personal Claude instruction")
    write(codex_root, "AGENTS.md", "Superseded personal Codex instruction")
    write(codex_root, "AGENTS.override.md", "Personal Codex override")

    assert {:ok, workspace} =
             Discovery.discover(workspace_root,
               personal_dir: lmx_root,
               claude_personal_dir: claude_root,
               codex_personal_dir: codex_root,
               agents_personal_dir: Path.join(tmp_dir, "agents")
             )

    prompt = Discovery.system_prompt(workspace, "base")
    assert prompt =~ "Personal temperament"
    assert prompt =~ "Personal durable fact"
    assert prompt =~ "Personal Claude instruction"
    assert prompt =~ "Personal portable instruction"
    assert prompt =~ "Personal Codex override"
    refute prompt =~ "Superseded personal Codex instruction"
  end

  test "manual-only skills stay out of the model catalog but remain user invocable", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))

    write(
      tmp_dir,
      ".claude/skills/deploy/SKILL.md",
      "---\nname: deploy\ndescription: Deploy production.\ndisable-model-invocation: true\n---\nDeploy"
    )

    assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false)
    refute Discovery.system_prompt(workspace, "base") =~ "deploy: Deploy production"
    assert Enum.map(Discovery.user_skills(workspace), & &1.name) == ["deploy"]
    assert Discovery.host_tools(workspace) == []
  end

  test "recomposing a recorded prompt replaces its marked workspace layer", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    write(tmp_dir, "AGENTS.md", "old instruction")

    assert {:ok, old_workspace} = Discovery.discover(tmp_dir, personal?: false)
    recorded = Discovery.system_prompt(old_workspace, "stable base")

    write(tmp_dir, "AGENTS.md", "new instruction")
    assert {:ok, new_workspace} = Discovery.discover(tmp_dir, personal?: false)
    refreshed = Discovery.system_prompt(new_workspace, recorded)

    assert refreshed =~ "stable base"
    assert refreshed =~ "new instruction"
    refute refreshed =~ "old instruction"
    assert length(:binary.matches(refreshed, "lmx-workspace-context:start")) == 1
  end

  test "legacy personal and project commands share modern skill invocation", %{tmp_dir: tmp_dir} do
    workspace_root = Path.join(tmp_dir, "workspace")
    personal_root = Path.join(tmp_dir, "personal")
    File.mkdir_p!(Path.join(workspace_root, ".git"))

    write(personal_root, "commands/team-check.md", "Check the team workflow.")

    write(
      workspace_root,
      ".claude/commands/release.md",
      "---\ndescription: Release one target.\nargument-hint: TARGET\n---\nRelease $ARGUMENTS"
    )

    assert {:ok, workspace} =
             Discovery.discover(workspace_root,
               personal_dir: personal_root,
               claude_personal_dir: Path.join(tmp_dir, "no-claude"),
               codex_personal_dir: Path.join(tmp_dir, "no-codex"),
               agents_personal_dir: Path.join(tmp_dir, "no-agents")
             )

    assert Enum.map(Discovery.user_skills(workspace), & &1.name) == ["release", "team-check"]
    assert [_skill_tool] = Discovery.host_tools(workspace)
    assert Discovery.system_prompt(workspace, "base") =~ "Release one target"
  end

  @hooks ~s|{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": []}]}}|
  @permissions ~s|{"permissions": {"allow": ["Bash(mix test:*)"]}}|

  test "diagnoses repository components that require explicit runtime trust", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    write(tmp_dir, ".mcp.json", "{}")
    write(tmp_dir, ".claude/rules/elixir.md", "use patterns")
    write(tmp_dir, ".claude/settings.local.json", @hooks)

    assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false)
    diagnostics = Enum.join(workspace.diagnostics, "\n")
    assert diagnostics =~ "path-scoped Claude rules are not imported"
    assert diagnostics =~ "Claude hooks are not executed"

    # `lmx` starts a repository's `.mcp.json`, and there is a flag for saying
    # no, so there is nothing left to warn about.
    refute diagnostics =~ "MCP"

    # Named relative to the repository. The absolute path is the part the
    # reader already knows, and it is long enough to push the remedy off the
    # line in a terminal.
    assert diagnostics =~ ".claude/rules: path-scoped Claude rules"
    refute diagnostics =~ tmp_dir
  end

  # Claude settings files mostly hold permissions and MCP enablement, neither
  # of which this harness has a concept of and neither of which is code.
  # Warning on the file's existence told every such repository its hooks would
  # not run when it had none.
  test "settings with no hooks in them are not a hooks warning", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    write(tmp_dir, ".claude/settings.json", @permissions)
    write(tmp_dir, ".claude/settings.local.json", ~s({"enableAllProjectMcpServers": true}))

    assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false)

    assert workspace.diagnostics == []
  end

  test "settings nobody can parse still warn, because not knowing is not knowing nothing",
       %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    write(tmp_dir, ".claude/settings.json", "{ this is not json")

    assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false)

    assert Enum.join(workspace.diagnostics, "\n") =~ "Claude hooks are not executed"
  end

  test "a warning whose remedy was already taken is not reported", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    write(tmp_dir, ".mcp.json", "{}")
    write(tmp_dir, ".claude/settings.json", @hooks)
    write(tmp_dir, ".claude/settings.local.json", @hooks)
    write(tmp_dir, ".claude/rules/elixir.md", "use patterns")

    assert {:ok, workspace} =
             Discovery.discover(tmp_dir, personal?: false, supplied: [:mcp_config, :hooks])

    diagnostics = Enum.join(workspace.diagnostics, "\n")

    refute diagnostics =~ "Claude hooks are not executed"

    # The ones with no flag to pass are still reported.
    assert diagnostics =~ "path-scoped Claude rules are not imported"
  end

  test "supplying hooks silences only the hooks warnings", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    write(tmp_dir, ".claude/rules/elixir.md", "use patterns")
    write(tmp_dir, ".claude/settings.json", @hooks)

    assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false, supplied: [:hooks])
    diagnostics = Enum.join(workspace.diagnostics, "\n")

    assert diagnostics =~ "path-scoped Claude rules are not imported"
    refute diagnostics =~ "Claude hooks are not executed"
  end

  describe "notices/2 and project_mcp_config/1" do
    # A host can have a repository to warn about and deliberately no
    # workspace, so the cheap half of the scan answers on its own.
    test "the notices are the same ones discovery reports", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      write(tmp_dir, ".claude/rules/elixir.md", "use patterns")
      write(tmp_dir, ".claude/settings.json", @hooks)

      assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false)
      assert Discovery.notices(tmp_dir) == workspace.diagnostics
      assert Discovery.notices(tmp_dir, supplied: [:hooks]) == [List.last(workspace.diagnostics)]
    end

    test "a repository's own MCP configuration is found from a subdirectory", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      write(tmp_dir, ".mcp.json", "{}")
      nested = Path.join([tmp_dir, "lib", "deep"])
      File.mkdir_p!(nested)

      # A `.mcp.json` belongs to the checkout, not to the directory you
      # happened to start in.
      assert Discovery.project_mcp_config(nested) == Path.join(tmp_dir, ".mcp.json")
    end

    test "a repository without one has nothing to load", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))

      assert Discovery.project_mcp_config(tmp_dir) == nil
    end
  end

  defp position(string, match), do: string |> :binary.match(match) |> elem(0)

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
