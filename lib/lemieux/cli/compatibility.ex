defmodule Lemieux.CLI.Compatibility do
  @moduledoc """
  A read-only migration inventory for `lmx explain`.

  Reports effective discovery and explicit exclusions, never imports vendor
  credentials, executes repository configuration or treats file presence as
  an applied feature. Instruction ordering is visible because loading two
  clients' files without saying which came later is a migration trap.
  """
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Extensions.Workspace.Discovery

  @doc "Reports current workspace inputs without their contents or secrets."
  @spec report(workspace :: Discovery.t() | nil) :: map()
  def report(nil),
    do: %{"status" => "workspace_not_loaded", "inputs" => [], "limitations" => limitations()}

  def report(workspace) do
    %{
      "status" => "discovered",
      "root" => workspace.root,
      "inputs" => inputs(workspace),
      "rules" => Enum.map(workspace.rule_files, &rule/1),
      "skills" => Enum.map(workspace.skills, &skill/1),
      "shadowed_skills" => Enum.map(workspace.shadowed_skills, &skill/1),
      "disabled_skills" => Enum.map(workspace.disabled_skills, &skill/1),
      "agents" =>
        Enum.map(
          workspace.agents,
          &%{"name" => &1.name, "path" => &1.path, "authority" => "read_only"}
        ),
      "diagnostics" => workspace.diagnostics,
      "unsupported_files" => unsupported(workspace.root),
      "precedence" =>
        "personal before repository; ancestor before nearer; AGENTS.override.md replaces AGENTS.md in the same directory; skill collision winners are listed separately",
      "limitations" => limitations()
    }
  end

  defp inputs(workspace) do
    Enum.flat_map(
      [
        {"persona", workspace.persona_files},
        {"instructions", workspace.instruction_files},
        {"memory", workspace.memory_files}
      ],
      fn {kind, files} ->
        Enum.with_index(files, fn {path, _contents}, position ->
          %{"kind" => kind, "path" => path, "position" => position}
        end)
      end
    )
  end

  defp rule(rule),
    do: %{
      "path" => rule.path,
      "root" => rule.root,
      "source" => Atom.to_string(rule.owner),
      "paths" => Enum.map(rule.patterns, & &1.source),
      "sha256" => rule.digest,
      "activation" => if(rule.patterns == [], do: "unconditional", else: "native_file_tool")
    }

  defp skill(skill),
    do: %{
      "name" => skill.name,
      "path" => skill.path,
      "builtin_collision" => builtin_collision(skill.name)
    }

  defp builtin_collision(name) do
    Enum.find_value(Builtin.all(), fn command ->
      spec = command.spec()
      if name in [spec.name | Map.get(spec, :aliases, [])], do: spec.name
    end)
  end

  defp unsupported(root) do
    [
      "opencode.json",
      "opencode.jsonc",
      ".cursor/rules",
      ".cursorrules",
      ".windsurfrules",
      ".codex/config.toml"
    ]
    |> Enum.filter(&File.exists?(Path.join(root, &1)))
    |> Enum.map(
      &%{
        "path" => &1,
        "status" => "not_imported",
        "remedy" => "port instructions to AGENTS.md or configure native host settings explicitly"
      }
    )
  end

  defp limitations do
    [
      "repository Claude settings hooks require explicit --hooks; their permission settings are not imported",
      "vendor login credentials and subscription entitlements are not imported or assumed",
      "agent definitions retain read-only authority; requested write tools are not granted",
      "scoped rules activate for native path/patch tools; shell and arbitrary external tools do not discover scopes",
      "rule imports are not expanded; use CLAUDE.md imports or portable instructions"
    ]
  end
end
