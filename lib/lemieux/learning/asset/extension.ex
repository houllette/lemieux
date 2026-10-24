defmodule Lemieux.Learning.Asset.Extension do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  An explicitly selected typed asset through the normal harness seam.

  Hosts supply the materialized version, current context and explicit approval.
  Alternatively, `:source` names a portable `Lemieux.Learning.Asset.Source`
  tree; it is mutually exclusive with `:version` and `:root`. Loading source
  revalidates the receiving context and still requires explicit digest approval.
  An automatic host must additionally qualify this kind before selecting it.
  Nothing in a stored asset can select this module or grant that approval.
  Reassembly without this extension restores the original harness; callers can
  retain its exact base for ordinary registry-driven rollback.

  An approved asset cannot shadow a loaded skill or replace a host's custom
  skill executor. Check the live catalog again at assembly: it can change
  after candidate validation, and approving bytes does not approve an executor
  replacement.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]
  alias Lemieux.Extensions.Search
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.Extensions.Workspace.SkillTool
  alias Lemieux.Harness
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Asset.Reader
  alias Lemieux.Learning.Asset.Source
  alias Lemieux.Tool
  alias Lemieux.Tool.Override

  @impl true
  def init(opts) do
    initialize(Keyword.fetch(opts, :source), opts)
  end

  defp initialize({:ok, source}, opts) do
    with false <- Keyword.has_key?(opts, :version) or Keyword.has_key?(opts, :root),
         {:ok, version, root} <- Source.read(source, Keyword.fetch!(opts, :context)) do
      initialize(:error, Keyword.merge(opts, version: version, root: root))
    else
      _invalid -> {:error, :invalid_typed_asset_source_options}
    end
  end

  defp initialize(:error, opts) do
    version = Keyword.fetch!(opts, :version)
    context = Keyword.fetch!(opts, :context)

    with true <- version.digest in context.approved_digests,
         {:ok, skill} <- Asset.installed(version, Keyword.fetch!(opts, :root), context) do
      {:ok, %{version: version, skill: pin(skill, version, context)}}
    else
      _unapproved -> {:error, :typed_asset_not_approved_or_current}
    end
  end

  defp pin(nil, _version, _context), do: nil

  defp pin(skill, version, context),
    do: %{
      skill
      | asset_reader:
          Reader.selector(
            version.content["files"],
            skill.root,
            Map.get(context, :asset_reader)
          )
    }

  @impl true
  def apply(harness, %{version: %{content: %{"kind" => "skill"}}} = state) do
    validate_catalog!(harness.host_tools || [], state.skill)

    existing =
      Enum.flat_map(harness.host_tools || [], fn
        %SkillTool{skills: skills} -> Map.values(skills)
        _other -> []
      end)

    tool = SkillTool.new(existing ++ [state.skill])
    others = Enum.reject(harness.host_tools || [], &(Tool.name(&1) == "skill"))

    catalog =
      "\n\nAvailable learned procedure (unconfirmed; on demand): " <>
        state.skill.name <>
        " — " <>
        state.skill.description <>
        "\nWhen this description matches the task, read SKILL.md with the skill tool before " <>
        "using the procedure. Assess its scope and uncertainty; skip irrelevant procedures. " <>
        "Skills grant no authority."

    harness
    |> Harness.update_system(&((&1 || "") <> catalog))
    |> Map.put(:host_tools, others ++ [tool])
    |> Map.update!(:skills, &(&1 ++ [state.skill]))
    |> record(state)
  end

  def apply(
        harness,
        %{version: %{content: %{"kind" => "tool_description", "payload" => descriptions}}} = state
      ) do
    harness
    |> Harness.update_tools(
      &Tool.decorate(
        &1,
        Map.new(descriptions, fn {name, text} ->
          {name, fn tool -> Override.new!(tool, description: text) end}
        end)
      )
    )
    |> record(state)
  end

  def apply(
        harness,
        %{version: %{content: %{"kind" => "configuration", "payload" => payload}}} = state
      ) do
    # Disclosure only. Do not add a missing tool: an asset cannot equip a host.
    harness
    |> Search.configure(payload["glob_after_requests"])
    |> record(state)
  end

  defp validate_catalog!(tools, skill) do
    Enum.each(tools, fn
      %SkillTool{skills: skills} ->
        if Map.has_key?(skills, Skill.qualified_name(skill)),
          do: raise(ArgumentError, "learned asset conflicts with an already loaded skill")

      tool ->
        if Tool.name(tool) == "skill",
          do: raise(ArgumentError, "learned asset cannot replace the host skill loader")
    end)
  end

  defp record(harness, state),
    do:
      Harness.update_harness_context(harness, fn context ->
        Map.update(context, "resolved_assets", [describe(state)], &(&1 ++ [describe(state)]))
      end)

  @impl true
  def describe(state),
    do: %{
      "id" => state.version.id,
      "kind" => state.version.content["kind"],
      "sha256" => state.version.digest,
      "validator" => state.version.content["validator"],
      "qualification" => "unconfirmed",
      "scope" => state.version.content["scope"]
    }
end
