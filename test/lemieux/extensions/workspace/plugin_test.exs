defmodule Lemieux.Extensions.Workspace.PluginTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Plugin
  alias Lemieux.Extensions.Workspace.Plugin.Marketplace
  alias Lemieux.Extensions.Workspace.Skill

  @moduletag :tmp_dir

  test "a manifest is optional and skills are namespaced", %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "quality")
    skill(plugin, "review")

    assert {:ok, loaded} = Plugin.read(plugin)
    assert loaded.name == "quality"
    assert [loaded_skill] = loaded.skills
    assert Skill.qualified_name(loaded_skill) == "quality:review"
  end

  test "unsupported components are reported rather than silently claimed", %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "wide")
    write(plugin, ".lsp.json", "{}")
    File.mkdir_p!(Path.join(plugin, "output-styles"))

    assert {:ok, loaded} = Plugin.read(plugin)
    assert Enum.any?(loaded.diagnostics, &String.contains?(&1, "unsupported LSP servers"))
    assert Enum.any?(loaded.diagnostics, &String.contains?(&1, "unsupported output styles"))
  end

  # Selecting a plugin is the trust decision, so what it carries is used —
  # with `${CLAUDE_PLUGIN_ROOT}` written in, since nothing here sets it.
  test "a selected plugin's agents, MCP servers and hooks are loaded", %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "wide")

    write(
      plugin,
      "agents/reviewer.md",
      "---\nname: reviewer\ndescription: Reviews changes.\ntools: Read, Bash\n---\nReview carefully."
    )

    write(
      plugin,
      ".mcp.json",
      JSON.encode!(%{
        "mcpServers" => %{
          "docs" => %{"command" => "${CLAUDE_PLUGIN_ROOT}/bin/docs-server", "args" => ["--stdio"]}
        }
      })
    )

    write(
      plugin,
      "hooks/hooks.json",
      JSON.encode!(%{
        "hooks" => %{
          "PostToolUse" => [
            %{
              "matcher" => "Write|Edit",
              "hooks" => [%{"type" => "command", "command" => "${CLAUDE_PLUGIN_ROOT}/format.sh"}]
            }
          ]
        }
      })
    )

    assert {:ok, loaded} = Plugin.read(plugin)

    assert [%{id: "wide-reviewer", tools: ["Read", "Bash"], source: {:plugin, "wide"}}] =
             loaded.agents

    # Named as Claude Code names a plugin's server, so a person's own `docs`
    # and this one are two servers, not one name for both.
    assert [%{"name" => "plugin_wide_docs", "source" => "plugin", "command" => command}] =
             loaded.mcp_servers

    assert command == Path.join(plugin, "bin/docs-server")

    assert [{:after_tool_call, hook}] = loaded.hooks
    assert inspect(hook) =~ Path.join(plugin, "format.sh")
    refute Enum.any?(loaded.diagnostics, &String.contains?(&1, "unsupported"))
  end

  test "a declared component that cannot be read costs only that component", %{
    tmp_dir: tmp_dir
  } do
    plugin = Path.join(tmp_dir, "partial")
    skill(plugin, "review")

    write(
      plugin,
      ".claude-plugin/plugin.json",
      JSON.encode!(%{
        "name" => "partial",
        "hooks" => "./hooks/missing.json",
        "mcpServers" => "./missing.json"
      })
    )

    assert {:ok, loaded} = Plugin.read(plugin)
    assert [_skill] = loaded.skills
    assert loaded.hooks == []
    assert loaded.mcp_servers == []
    assert Enum.any?(loaded.diagnostics, &String.contains?(&1, "plugin hooks were not loaded"))
    assert Enum.any?(loaded.diagnostics, &String.contains?(&1, "MCP servers were not loaded"))
  end

  test "inline MCP servers and hooks in the manifest are read too", %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "inline")

    write(
      plugin,
      ".claude-plugin/plugin.json",
      JSON.encode!(%{
        "name" => "inline",
        "mcpServers" => %{"api" => %{"url" => "https://example.com/mcp"}},
        "hooks" => %{
          "Stop" => [%{"hooks" => [%{"type" => "command", "command" => "true"}]}]
        }
      })
    )

    assert {:ok, loaded} = Plugin.read(plugin)

    assert [%{"name" => "plugin_inline_api", "url" => "https://example.com/mcp"}] =
             loaded.mcp_servers

    assert [{:stop, _hook}] = loaded.hooks
  end

  test "loads legacy commands and a root skill as namespaced invocable skills", %{
    tmp_dir: tmp_dir
  } do
    plugin = Path.join(tmp_dir, "workflow")

    write(
      plugin,
      "commands/release.md",
      "---\ndescription: Release safely.\n---\nRelease $ARGUMENTS"
    )

    assert {:ok, loaded} = Plugin.read(plugin)
    assert [command] = loaded.skills
    assert Skill.qualified_name(command) == "workflow:release"
    refute Enum.any?(loaded.diagnostics, &String.contains?(&1, "unsupported commands"))

    root_plugin = Path.join(tmp_dir, "root-skill")

    write(
      root_plugin,
      "SKILL.md",
      "---\nname: inspect\ndescription: Inspect a release.\n---\nInspect it"
    )

    assert {:ok, root_loaded} = Plugin.read(root_plugin)
    assert [root_skill] = root_loaded.skills
    assert Skill.qualified_name(root_skill) == "root-skill:inspect"
  end

  test "custom skills supplement defaults while custom commands replace their default", %{
    tmp_dir: tmp_dir
  } do
    plugin = Path.join(tmp_dir, "custom")

    write(
      plugin,
      ".claude-plugin/plugin.json",
      JSON.encode!(%{
        "name" => "custom",
        "skills" => ["./capabilities"],
        "commands" => "./workflows"
      })
    )

    write(
      plugin,
      "capabilities/audit/SKILL.md",
      "---\nname: audit\ndescription: Audit a change.\n---\nAudit"
    )

    skill(plugin, "review")
    write(plugin, "commands/ignored.md", "This default command is replaced.")
    write(plugin, "workflows/release.md", "Release the selected target.")

    assert {:ok, loaded} = Plugin.read(plugin)

    assert Enum.map(loaded.skills, &Skill.qualified_name/1) == [
             "custom:audit",
             "custom:release",
             "custom:review"
           ]

    refute Enum.any?(loaded.diagnostics, &String.contains?(&1, "unsupported commands"))
  end

  test "custom paths accept a root skill and individual command file", %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "direct")

    write(
      plugin,
      ".claude-plugin/plugin.json",
      JSON.encode!(%{
        "name" => "direct",
        "skills" => "./",
        "commands" => "./workflows/release.md"
      })
    )

    write(
      plugin,
      "SKILL.md",
      "---\nname: inspect\ndescription: Inspect a target.\n---\nInspect ${CLAUDE_PLUGIN_ROOT} and ${CLAUDE_SKILL_DIR}"
    )

    write(plugin, "workflows/release.md", "Release one target.")

    assert {:ok, loaded} = Plugin.read(plugin)

    assert Enum.map(loaded.skills, &Skill.qualified_name/1) == [
             "direct:inspect",
             "direct:release"
           ]

    inspect_skill = Enum.find(loaded.skills, &(&1.name == "inspect"))
    assert {:ok, rendered} = Skill.render(inspect_skill)
    assert rendered =~ "Inspect #{plugin} and #{plugin}"
  end

  test "manifest component paths cannot escape the plugin", %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "escape")

    write(
      plugin,
      ".claude-plugin/plugin.json",
      JSON.encode!(%{"name" => "escape", "skills" => "./../outside"})
    )

    assert {:error, reason} = Plugin.read(plugin)
    assert reason =~ "skills path escapes plugin root"
  end

  test "a skill symlink cannot escape the plugin root", %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "linked")
    outside = Path.join(tmp_dir, "outside/review")

    write(
      outside,
      "SKILL.md",
      "---\nname: review\ndescription: Read outside.\n---\noutside"
    )

    File.mkdir_p!(Path.join(plugin, "skills"))
    File.ln_s!(outside, Path.join(plugin, "skills/review"))

    assert {:ok, loaded} = Plugin.read(plugin)
    assert loaded.skills == []
    assert Enum.any?(loaded.diagnostics, &String.contains?(&1, "escapes plugin root"))
  end

  test "a local marketplace resolves only selected relative plugins", %{tmp_dir: tmp_dir} do
    skill(Path.join(tmp_dir, "plugins/quality"), "review")

    marketplace(tmp_dir, [
      %{"name" => "quality", "source" => "./plugins/quality"}
    ])

    assert {:ok, catalog} = Marketplace.read(tmp_dir)
    assert catalog.name == "team"
    assert {:ok, plugin} = Marketplace.resolve(catalog, "quality@team")
    assert plugin.name == "quality"
    assert [skill] = plugin.skills
    assert Skill.qualified_name(skill) == "quality:review"
  end

  test "a marketplace entry can supplement prompt components", %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "plugins/workflow")
    skill(plugin, "review")
    write(plugin, "workflows/release.md", "Release one target.")

    marketplace(tmp_dir, [
      %{
        "name" => "workflow",
        "source" => "./plugins/workflow",
        "commands" => "./workflows/release.md"
      }
    ])

    assert {:ok, catalog} = Marketplace.read(tmp_dir)
    assert {:ok, loaded} = Marketplace.resolve(catalog, "workflow@team")

    assert Enum.map(loaded.skills, &Skill.qualified_name/1) == [
             "workflow:release",
             "workflow:review"
           ]
  end

  test "strict false refuses conflicting component declarations", %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "plugins/conflict")

    write(
      plugin,
      ".claude-plugin/plugin.json",
      JSON.encode!(%{"name" => "conflict", "commands" => "./commands"})
    )

    marketplace(tmp_dir, [
      %{
        "name" => "conflict",
        "source" => "./plugins/conflict",
        "commands" => "./other",
        "strict" => false
      }
    ])

    assert {:ok, catalog} = Marketplace.read(tmp_dir)
    assert {:error, reason} = Marketplace.resolve(catalog, "conflict@team")
    assert reason =~ "strict: false conflicts"
  end

  test "a selected remote git plugin is materialized and cached", %{tmp_dir: tmp_dir} do
    repository = Path.join(tmp_dir, "remote-plugin")
    skill(repository, "review")
    sha = commit(repository)

    marketplace(tmp_dir, [
      %{
        "name" => "remote",
        "source" => %{
          "source" => "url",
          "url" => "file://#{repository}",
          "ref" => "main",
          "sha" => sha
        }
      }
    ])

    assert {:ok, catalog} = Marketplace.read(tmp_dir)

    cache = Path.join(tmp_dir, "cache")
    assert {:ok, plugin} = Marketplace.resolve(catalog, "remote@team", cache_dir: cache)

    assert plugin.name == "remote"
    assert [loaded_skill] = plugin.skills
    assert Skill.qualified_name(loaded_skill) == "remote:review"

    no_git = fn _args -> raise "a pinned cache hit must not invoke git" end

    assert {:ok, _cached} =
             Marketplace.resolve(catalog, "remote@team", cache_dir: cache, git: no_git)
  end

  test "a remote git marketplace retains relative plugin sources", %{tmp_dir: tmp_dir} do
    repository = Path.join(tmp_dir, "remote-marketplace")
    skill(Path.join(repository, "plugins/quality"), "review")

    marketplace(repository, [
      %{"name" => "quality", "source" => "./plugins/quality"}
    ])

    commit(repository)

    assert {:ok, catalog} =
             Marketplace.read("file://#{repository}", cache_dir: Path.join(tmp_dir, "cache"))

    assert {:ok, plugin} = Marketplace.resolve(catalog, "quality@team")
    assert [loaded_skill] = plugin.skills
    assert Skill.qualified_name(loaded_skill) == "quality:review"
  end

  test "a direct marketplace URL is fetched but cannot anchor relative plugins", %{
    tmp_dir: tmp_dir
  } do
    body =
      JSON.encode!(%{
        "name" => "remote",
        "plugins" => [%{"name" => "quality", "source" => "./plugins/quality"}]
      })

    get = fn "https://example.test/marketplace.json" -> {:ok, 200, body} end

    assert {:ok, catalog} =
             Marketplace.read("https://example.test/marketplace.json",
               get: get,
               cache_dir: Path.join(tmp_dir, "cache")
             )

    assert catalog.root == nil
    assert {:error, reason} = Marketplace.resolve(catalog, "quality@remote")
    assert reason =~ "direct marketplace.json URL has no repository root"
    refute File.exists?(Path.join(tmp_dir, "plugins/quality"))
  end

  # The pin is fetched and checked out whatever the branch says, so a pin the
  # repository does not have is a fetch that fails, naming the pin.
  test "a pinned remote plugin refuses a revision the repository does not have", %{
    tmp_dir: tmp_dir
  } do
    repository = Path.join(tmp_dir, "pinned-plugin")
    skill(repository, "review")
    commit(repository)

    marketplace(tmp_dir, [
      %{
        "name" => "remote",
        "source" => %{
          "source" => "url",
          "url" => "file://#{repository}",
          "ref" => "main",
          "sha" => String.duplicate("0", 40)
        }
      }
    ])

    assert {:ok, catalog} = Marketplace.read(tmp_dir)

    assert {:error, reason} =
             Marketplace.resolve(catalog, "remote@team", cache_dir: Path.join(tmp_dir, "cache"))

    assert reason =~ "could not fetch pinned #{String.duplicate("0", 40)}"
  end

  test "a remote plugin URL cannot be interpreted as a git option", %{tmp_dir: tmp_dir} do
    marketplace(tmp_dir, [
      %{"name" => "remote", "source" => %{"source" => "url", "url" => "--upload-pack=bad"}}
    ])

    assert {:ok, catalog} = Marketplace.read(tmp_dir)
    assert {:error, reason} = Marketplace.resolve(catalog, "remote@team")
    assert reason =~ "invalid remote plugin git URL"
  end

  test "a relative source may not escape its marketplace", %{tmp_dir: tmp_dir} do
    marketplace(tmp_dir, [%{"name" => "escape", "source" => "./../escape"}])

    assert {:ok, catalog} = Marketplace.read(tmp_dir)
    assert {:error, reason} = Marketplace.resolve(catalog, "escape@team")
    assert reason =~ "escapes marketplace root"
  end

  test "a relative source may not escape through a symbolic link", %{tmp_dir: tmp_dir} do
    skill(Path.join(tmp_dir, "outside"), "review")
    File.mkdir_p!(Path.join(tmp_dir, "market/plugins"))
    File.ln_s!(Path.join(tmp_dir, "outside"), Path.join(tmp_dir, "market/plugins/escape"))

    marketplace(Path.join(tmp_dir, "market"), [
      %{"name" => "escape", "source" => "./plugins/escape"}
    ])

    assert {:ok, catalog} = Marketplace.read(Path.join(tmp_dir, "market"))
    assert {:error, reason} = Marketplace.resolve(catalog, "escape@team")
    assert reason =~ "escapes marketplace root"
  end

  defp marketplace(root, plugins) do
    write(
      root,
      ".claude-plugin/marketplace.json",
      JSON.encode!(%{"name" => "team", "plugins" => plugins})
    )
  end

  defp skill(plugin, name) do
    write(
      plugin,
      "skills/#{name}/SKILL.md",
      "---\nname: #{name}\ndescription: Use #{name} when it applies.\n---\nbody"
    )
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp commit(repository) do
    File.mkdir_p!(repository)
    git!(repository, ["init", "-b", "main"])
    git!(repository, ["add", "."])

    git!(repository, [
      "-c",
      "user.name=Lemieux",
      "-c",
      "user.email=lmx@example.test",
      "commit",
      "-m",
      "fixture"
    ])

    repository |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(repository, args) do
    {output, status} = System.cmd("git", ["-C", repository | args], stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
