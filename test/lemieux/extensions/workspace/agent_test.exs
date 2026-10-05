defmodule Lemieux.Extensions.Workspace.AgentTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Delegation
  alias Lemieux.Extensions.Workspace.Agent
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Harness
  alias Lemieux.Subagent.Delegate
  alias Lemieux.Tool

  @moduletag :tmp_dir

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp agent_file(name, extra \\ "") do
    """
    ---
    name: #{name}
    description: Reviews a change for correctness.
    #{extra}
    ---
    You review diffs. Cite files and lines.
    """
  end

  describe "read/2" do
    test "maps a Claude definition, keeping the tools it asks for as names", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "reviewer.md", agent_file("code-reviewer", "tools: Read, Grep, Bash"))

      assert {:ok, agent} = Agent.read(path)
      assert agent.id == "code-reviewer"
      assert agent.description == "Reviews a change for correctness."
      assert agent.prompt == "You review diffs. Cite files and lines."
      assert agent.tools == ["Read", "Grep", "Bash"]
      assert agent.model == nil
      assert agent.diagnostics == []
    end

    # What `/agents` in Claude Code writes, and what lmx used to refuse with a
    # parser error struct on every start: a one-line description with a colon
    # in it and literal \n sequences.
    test "reads a Claude Code agent whose description is not strict YAML", %{tmp_dir: tmp_dir} do
      contents =
        "---\n" <>
          "name: elixir-expert\n" <>
          "description: Use this agent for Elixir, including: writing tests first.\\n\\nExamples:\\n- User: 'help'\n" <>
          "model: inherit\n" <>
          "color: purple\n" <>
          "---\n" <>
          "You write tests first.\n"

      assert {:ok, agent} = Agent.read(write(tmp_dir, "elixir-expert.md", contents))
      assert agent.id == "elixir-expert"
      assert agent.description =~ "including: writing tests first.\n\nExamples:"
      assert agent.prompt == "You write tests first."
    end

    test "absent tools mean the default read-only set", %{tmp_dir: tmp_dir} do
      assert {:ok, %{tools: :default}} =
               Agent.read(write(tmp_dir, "a.md", agent_file("helper")))
    end

    test "Claude model aliases fall back to the scout's model; a provider:model is kept", %{
      tmp_dir: tmp_dir
    } do
      assert {:ok, %{model: nil, diagnostics: [alias_note]}} =
               Agent.read(write(tmp_dir, "a.md", agent_file("aliased", "model: sonnet")))

      assert alias_note =~ "Claude alias"

      assert {:ok, %{model: nil, diagnostics: []}} =
               Agent.read(write(tmp_dir, "b.md", agent_file("inherits", "model: inherit")))

      assert {:ok, %{model: "openai:gpt-5-mini"}} =
               Agent.read(
                 write(tmp_dir, "c.md", agent_file("chosen", "model: openai:gpt-5-mini"))
               )
    end

    test "ids are made safe and prefixed by a plugin namespace", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "a.md", agent_file("Code Reviewer!"))

      assert {:ok, %{id: "code-reviewer"}} = Agent.read(path)
      assert {:ok, %{id: "quality-code-reviewer"}} = Agent.read(path, namespace: "quality")
    end

    test "malformed files are refused with the reason", %{tmp_dir: tmp_dir} do
      assert {:error, message} = Agent.read(write(tmp_dir, "plain.md", "just prose"))
      assert message =~ "frontmatter"

      assert {:error, message} =
               Agent.read(write(tmp_dir, "nodesc.md", "---\nname: x\n---\nprompt"))

      assert message =~ "description"

      assert {:error, message} =
               Agent.read(write(tmp_dir, "empty.md", "---\nname: x\ndescription: y\n---\n\n"))

      assert message =~ "instructions"

      assert {:error, message} =
               Agent.read(write(tmp_dir, "scout.md", agent_file("repository-scout")))

      assert message =~ "built-in scout"
    end
  end

  test "discovery finds personal and repository agents, the repository's winning", %{
    tmp_dir: tmp_dir
  } do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    personal = Path.join(tmp_dir, "claude-home")

    write(personal, "agents/reviewer.md", agent_file("reviewer") <> "\npersonal version")
    write(personal, "agents/researcher.md", agent_file("researcher"))
    write(repo, ".claude/agents/reviewer.md", agent_file("reviewer") <> "\nrepository version")
    write(repo, ".claude/agents/broken.md", "no frontmatter")

    assert {:ok, workspace} =
             Discovery.discover(repo,
               personal_dir: Path.join(tmp_dir, "lmx-home"),
               claude_personal_dir: personal,
               codex_personal_dir: Path.join(tmp_dir, "codex-home"),
               agents_personal_dir: Path.join(tmp_dir, "agents-home")
             )

    assert Enum.map(workspace.agents, & &1.id) == ["researcher", "reviewer"]
    reviewer = Enum.find(workspace.agents, &(&1.id == "reviewer"))
    assert reviewer.prompt =~ "repository version"
    assert Enum.any?(workspace.diagnostics, &(&1 =~ "broken.md needs YAML frontmatter"))
  end

  describe "delegation" do
    defp delegate_with(agents) do
      workspace = %Discovery{root: "/repo", agents: agents}

      {:ok, harness} =
        Harness.assemble(Harness.new(workspace: workspace), [
          {Delegation, model: "test:parent", scout_model: "test:scout", priced?: true}
        ])

      {List.last(harness.tools), harness.notices}
    end

    defp agent(attrs) do
      struct!(
        Agent,
        Keyword.merge(
          [
            id: "reviewer",
            name: "reviewer",
            description: "Reviews changes",
            prompt: "Review.",
            path: "/repo/.claude/agents/reviewer.md"
          ],
          attrs
        )
      )
    end

    test "workspace agents join the scout, reading only, on the scout's model" do
      {%Delegate{definitions: definitions}, notices} =
        delegate_with([agent(tools: ["Read", "Grep", "Bash", "Edit"])])

      assert Map.keys(definitions) |> Enum.sort() == ["repository-scout", "reviewer"]
      reviewer = definitions["reviewer"]
      assert reviewer.model == "test:scout"
      assert reviewer.system_prompt == "Review."
      assert Enum.map(reviewer.tools, &Tool.name/1) == ~w(read grep)
      assert reviewer.max_cost_usd == definitions["repository-scout"].max_cost_usd

      assert [notice] = notices
      assert notice =~ "subagent reviewer: Bash, Edit are not available to read-only subagents"
    end

    test "an agent naming its own model is bounded in requests" do
      {%Delegate{definitions: definitions}, []} =
        delegate_with([agent(model: "openai:gpt-5-mini")])

      assert %{model: "openai:gpt-5-mini", max_requests: requests, max_cost_usd: nil} =
               definitions["reviewer"]

      assert is_integer(requests) and requests > 0
    end

    test "an agent asking only for tools it cannot have still reads" do
      {%Delegate{definitions: %{"reviewer" => reviewer}}, [_notice]} =
        delegate_with([agent(tools: ["Bash"])])

      assert Enum.map(reviewer.tools, &Tool.name/1) == ["read"]
    end

    test "the scout runs on the scout model, and without a workspace is alone" do
      {:ok, harness} =
        Harness.assemble(Harness.new(), [
          {Delegation, model: "test:parent", scout_model: "test:scout", priced?: true}
        ])

      %Delegate{definitions: definitions} = List.last(harness.tools)
      assert Map.keys(definitions) == ["repository-scout"]
      assert definitions["repository-scout"].model == "test:scout"
      assert harness.notices == []
    end
  end
end
