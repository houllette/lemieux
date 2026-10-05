defmodule Lemieux.Extensions.Workspace do
  @moduledoc """
  The filesystem experience: persona, instructions, memory, skills, plugins
  and the learned overlay, composed into the harness.

  This is the part of `lmx` that makes the TUI batteries-included, and it is
  an extension rather than something the session does because it is host
  setup, not agent-loop policy. An embedder may assemble its prompt from a
  database, an API or a sandbox image; the CLI has a filesystem and follows
  the portable conventions coding repositories already use. The TUI applies
  this; `lmx run` and library hosts get exactly the prompt and
  tools they supplied unless they apply it too.

  `Lemieux.Extensions.Workspace.Discovery` does the reading and holds the
  rules — which files, in which order, what wins. This module is what its
  result does to a harness:

    * the **prompt** gains the persona, instructions, memory, skill catalog
      and learned suffix, composed over whatever prompt is there. The layer
      is delimited by markers so a resume can replace it with the current
      files rather than stacking a second copy — `Discovery.system_prompt/2`
      keeps that protocol;
    * the **host tools** gain the allowlisted `skill` loader when any
      discovered skill is model-invocable. A host tool, not a catalog tool,
      because skill paths are valid only in this runtime;
    * the **catalog** takes the learned overlay's tool descriptions — the
      person's own overlay's only; a repository's may add prompt text, not
      re-describe tools (see `Lemieux.Extensions.Workspace.Discovery`) —
      through `Lemieux.Tool.decorate/2`, and
      `harness_context["resolved_assets"]` records the overlay so every
      request's snapshot says which learned layer applied. A workspace
      without an overlay leaves the catalog untouched, which on a resume is
      the difference between keeping the recorded tools and replacing them;
    * the host fields `skills` (what a screen offers as slash commands) and
      `notices` (what the scan wants the person to know — a repository
      overlay in force, an import or a symlinked file that was not read, a
      plugin that could not be loaded) are filled, and
      `workspace` holds the discovery for whoever wants to read it —
      including the subagent definitions it found, which
      `Lemieux.Extensions.Delegation` offers beside the scout;
    * a selected plugin's **MCP servers and hooks** join the harness's.
      Selecting the plugin was the trust decision (see
      `Lemieux.Extensions.Workspace.Plugin`); a repository's own
      `.claude/settings.json` hooks are still never run from here.

  Applied by the host at session start and recorded in the snapshot, never
  restored from a transcript: a resumed session gets the current files, not
  a stale layer.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Harness
  alias Lemieux.Learning.Overlay

  @doc """
  Discovers the workspace, or takes one already discovered.

  `workspace: %Discovery{}` uses that discovery — the TUI discovers once,
  before the screen opens, and applies the same result to every session it
  starts. Otherwise `:cwd` (defaulting to the current directory) and the
  remaining options go to `Discovery.discover/2`: `:skill_dirs`,
  `:bundled_skills?`, `:system_skill_dirs`, `:disabled_skills`,
  `:plugin_dirs`, `:marketplaces`, `:plugins`, `:marketplace_fetch`,
  `:personal?`, `:personal_dir`, `:claude_personal_dir`,
  `:codex_personal_dir`, `:agents_personal_dir`, `:home` and `:supplied`.
  """
  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, Discovery.t()} | {:error, String.t()}
  def init(opts) do
    case Keyword.fetch(opts, :workspace) do
      {:ok, %Discovery{} = workspace} ->
        {:ok, workspace}

      {:ok, other} ->
        {:error,
         "workspace: wants a %Lemieux.Extensions.Workspace.Discovery{}; got #{inspect(other)}"}

      :error ->
        {cwd, opts} = Keyword.pop_lazy(opts, :cwd, &File.cwd!/0)
        Discovery.discover(cwd, opts)
    end
  end

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, %Discovery{} = workspace) do
    harness
    |> Harness.update_system(&compose(workspace, &1))
    |> Harness.append_host_tools(Discovery.host_tools(workspace))
    |> overlay(workspace)
    |> plugin_components(workspace)
    |> Map.update!(:skills, &(&1 ++ Discovery.user_skills(workspace)))
    |> Map.update!(:notices, &(&1 ++ workspace.diagnostics))
    |> Map.put(:workspace, workspace)
  end

  # Appending nothing leaves either field as it was, so a resume keeps the
  # servers and hooks its host supplied rather than gaining empty lists.
  defp plugin_components(harness, %Discovery{} = workspace) do
    harness
    |> Harness.append_mcp_servers(workspace.mcp_servers)
    |> Harness.append_hooks(workspace.hooks)
  end

  # A host that disabled the prompt outright gets the workspace layer alone,
  # and still no prompt when there is no layer to add.
  defp compose(workspace, nil) do
    case Discovery.system_prompt(workspace, "") do
      "" -> nil
      composed -> composed
    end
  end

  defp compose(workspace, base) when is_binary(base), do: Discovery.system_prompt(workspace, base)

  defp overlay(harness, %Discovery{overlay: nil}), do: harness

  defp overlay(harness, %Discovery{overlay: %Overlay{}} = workspace) do
    assets = Discovery.resolved_assets(workspace)

    harness
    |> Harness.update_tools(&Discovery.overlay_tools(workspace, &1))
    |> Harness.update_harness_context(fn context ->
      Map.update(context, "resolved_assets", assets, &(&1 ++ assets))
    end)
  end

  @impl Lemieux.Extension
  def describe(%Discovery{} = workspace) do
    %{
      "root" => workspace.root,
      "skills" => length(workspace.skills),
      "agents" => length(workspace.agents),
      "plugin_mcp_servers" => Enum.map(workspace.mcp_servers, & &1["name"]),
      "plugin_hooks" => length(workspace.hooks),
      "overlay_sha256" => workspace.overlay && workspace.overlay.sha256
    }
  end
end
