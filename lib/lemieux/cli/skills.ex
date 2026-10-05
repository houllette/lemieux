defmodule Lemieux.CLI.Skills do
  @moduledoc """
  `lmx skills [--json]` — every Agent Skill and legacy command a session
  started here finds, where each came from, and whether it is enabled.

  Skills reach a session from many places — bundled, Omarchy, four personal
  directories, the repository, `--skill-dir`, plugins — and one skill is
  often reachable from several of them: Omarchy links its skills into
  `~/.claude/skills` and `~/.codex/skills`. A catalog that only lists
  names cannot say why the model was offered one copy and not another, or
  why a skill a person can see on disk is missing. This lists, for each
  name, the copy that won, the copies it hid (and whether they are the same
  file through a link or a different file it overrides), the real path when
  a link points elsewhere, and the state: enabled, disabled in the config,
  invoked only by the person (`disable-model-invocation`) or only by the
  model (`user-invocable: false`). It also says whether Omarchy discovery is
  on and where it looked, and prints discovery's notices about skills.

  It discovers exactly as `lmx run` does — the same function
  (`Lemieux.CLI.Runtime.discover_workspace/2`) with the same options
  (`discovery_options/2`), and it honours `-C DIR`, `--config`,
  `--skill-dir`, `--plugin-dir`, `--plugin` and `--marketplace` the way
  `lmx run` does — so what it lists is what a session would load, not a
  second opinion. It sends no model request and starts nothing; a remote
  marketplace named with `--marketplace` is fetched, as for a session.

  Every name and path it prints came from a file somebody else may have
  written, so text goes through `Lemieux.CLI.Sanitize.visible/1` and JSON
  through `Lemieux.CLI.Sanitize.json/1`.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Sanitize
  alias Lemieux.CLI.SystemSkills
  alias Lemieux.Extensions.Workspace.Containment
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Extensions.Workspace.Skill

  @switches [
    config: :string,
    skill_dir: [:string, :keep],
    plugin_dir: [:string, :keep],
    marketplace: [:string, :keep],
    plugin: [:string, :keep],
    json: :boolean
  ]

  @usage "usage: lmx skills [--json] [--skill-dir D] [--plugin-dir D] [--marketplace S] " <>
           "[--plugin N@M] [--config PATH|none]"

  @doc """
  The skill options `Lemieux.CLI.Runtime.discover_workspace/2` adds to
  discovery: the system skill roots (`Lemieux.CLI.SystemSkills`) and the
  names `"skills": {"disabled": [...]}` leaves out.

  System skills are read where personal ones are, `:personal?` in `opts`:
  a run that reads none of the person's files (`lmx run --config none`
  without `LMX_HOME`) reads no machine-specific skills either, so its prompt
  is the same on every machine — the repeatability that mode exists for.
  `:system_skill_dirs` in `opts` replaces the detection, and
  `:system_skills` is passed to it (`Lemieux.CLI.SystemSkills.report/2`'s
  `:env`, `:home` and `:packaged`).
  """
  @spec discovery_options(options :: Options.t(), opts :: keyword()) :: keyword()
  def discovery_options(%Options{config: config}, opts) when is_list(opts) do
    system =
      Keyword.get_lazy(opts, :system_skill_dirs, fn ->
        if Keyword.get(opts, :personal?, true),
          do: SystemSkills.roots(config, Keyword.get(opts, :system_skills, [])),
          else: []
      end)

    [system_skill_dirs: system, disabled_skills: disabled(config)]
  end

  @doc "Runs `lmx skills`, printing the report; never halts."
  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    {parsed, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    with [] <- invalid,
         [] <- rest,
         forwarded = parsed |> Keyword.delete(:json) |> OptionParser.to_argv(),
         {:ok, options} <- Options.parse(forwarded, command: :explain) do
      personal? = Keyword.get(opts, :personal?, is_binary(options.host.state_dir))
      opts = Keyword.put(opts, :personal?, personal?)
      # Looked up once, so the roots reported are the roots discovery read.
      opts =
        Keyword.merge(opts, Keyword.take(discovery_options(options, opts), [:system_skill_dirs]))

      case Runtime.discover_workspace(options, opts) do
        {:ok, workspace} -> print(report(workspace, options, opts), parsed[:json] == true)
        {:error, reason} -> fail(reason)
      end
    else
      [{flag, value} | _invalid] -> fail(invalid(flag, value))
      [word | _rest] when is_binary(word) -> fail("unexpected argument #{word}; #{@usage}")
      {:error, message} -> fail(message)
    end
  end

  # OptionParser reports an unknown switch, and a known one missing its
  # value, the same way: `{flag, nil}`.
  defp invalid(flag, value) do
    known? = Enum.any?(@switches, fn {key, _type} -> flag == "--" <> dashed(key) end)

    cond do
      known? and is_nil(value) -> "missing value for #{flag}"
      known? -> "invalid value for #{flag}"
      true -> "unrecognised option #{flag}; #{@usage}"
    end
  end

  defp dashed(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp disabled(config), do: Map.get(Config.get(config, "skills", %{}), "disabled", [])

  defp report(%Discovery{} = workspace, %Options{config: config}, opts) do
    system = SystemSkills.report(config, Keyword.get(opts, :system_skills, []))
    shadowed = Enum.group_by(workspace.shadowed_skills, &Skill.qualified_name/1)
    found = Enum.map(workspace.skills ++ workspace.disabled_skills, &Skill.qualified_name/1)

    context = %{
      root: workspace.root,
      home: workspace.home,
      omarchy: system.omarchy.root
    }

    skills =
      (Enum.map(workspace.skills, &{&1, state(&1)}) ++
         Enum.map(workspace.disabled_skills, &{&1, :disabled}))
      |> Enum.sort_by(fn {skill, _state} -> Skill.qualified_name(skill) end)
      |> Enum.map(fn {skill, state} ->
        entry(skill, state, Map.get(shadowed, Skill.qualified_name(skill), []), context)
      end)

    %{
      directory: Keyword.get_lazy(opts, :cwd, &File.cwd!/0),
      root: workspace.root,
      skills: skills,
      personal?: Keyword.fetch!(opts, :personal?),
      system_skill_dirs: Keyword.fetch!(opts, :system_skill_dirs),
      omarchy: system.omarchy,
      disabled: disabled(config),
      not_found: Enum.reject(disabled(config), &(&1 in found)),
      diagnostics: workspace.skill_diagnostics,
      context: context
    }
  end

  # Whether a link between the root a skill was found under and its
  # `SKILL.md` — the skill's directory, or the file — sends it elsewhere. A
  # link above that root (macOS's `/var`, a build's `priv`) moves every
  # skill under it alike and says nothing about this one.
  defp linked?(%Skill{real_path: nil}), do: false

  defp linked?(%Skill{path: path, real_path: real} = skill) do
    case found_under(skill) do
      nil -> real != path
      root -> real != Path.join(Containment.real_path(root), Path.relative_to(path, root))
    end
  end

  defp found_under(%Skill{source: {:plugin, _id}, plugin_root: root}), do: root
  defp found_under(%Skill{source: {_kind, root}}) when is_binary(root), do: root
  defp found_under(%Skill{}), do: nil

  defp state(%Skill{model_invocable?: true, user_invocable?: true}), do: :enabled
  defp state(%Skill{model_invocable?: false, user_invocable?: true}), do: :user_only
  defp state(%Skill{model_invocable?: true, user_invocable?: false}), do: :model_only
  defp state(%Skill{}), do: :not_invocable

  # The copies a name hid, the nearest in precedence first.
  defp entry(skill, state, shadowed, context) do
    %{
      skill: skill,
      state: state,
      from: from(skill.source, context),
      shadowed:
        shadowed
        |> Enum.reverse()
        |> Enum.map(&%{skill: &1, from: from(&1.source, context), same?: same_file?(&1, skill)})
    }
  end

  defp same_file?(%Skill{real_path: real}, %Skill{real_path: real}) when is_binary(real), do: true
  defp same_file?(_lost, _kept), do: false

  defp from({:bundled, _root}, _context), do: "bundled"
  defp from({:system, root}, %{omarchy: root}), do: "omarchy"
  defp from({:system, root}, context), do: "system #{shown(root, context)}"
  defp from({:personal, root}, context), do: "personal #{shown(root, context)}"
  defp from({:repository, root}, context), do: "repository #{relative(root, context.root)}"
  defp from({:skill_dir, root}, context), do: "--skill-dir #{shown(root, context)}"
  defp from({:plugin, id}, _context), do: "plugin #{id}"
  defp from(other, _context), do: inspect(other)

  defp source({kind, _where}) when is_atom(kind), do: Atom.to_string(kind)
  defp source(_other), do: "other"

  # A repository's file relative to the repository, anything under the home
  # directory with `~`, and the rest as it is.
  defp shown_path(%Skill{source: {:repository, _root}}, path, context),
    do: relative(path, context.root)

  defp shown_path(_skill, path, context), do: shown(path, context)

  defp shown(path, %{home: home}) when is_binary(home) do
    if under?(path, home), do: "~/" <> Path.relative_to(path, home), else: path
  end

  defp shown(path, _context), do: path

  defp relative(path, root) do
    cond do
      path == root -> "."
      under?(path, root) -> Path.relative_to(path, root)
      true -> path
    end
  end

  defp under?(path, directory),
    do: String.starts_with?(path, String.trim_trailing(directory, "/") <> "/")

  defp print(report, true) do
    report |> json() |> JSON.encode!() |> Sanitize.json() |> IO.puts()
  end

  defp print(report, false), do: report |> text() |> IO.write()

  defp json(report) do
    %{
      "version" => 1,
      "directory" => report.directory,
      "root" => report.root,
      "skills" => Enum.map(report.skills, &json_entry/1),
      "personal" => report.personal?,
      "system_skill_dirs" => report.system_skill_dirs,
      "omarchy" => %{
        "enabled" => report.omarchy.enabled?,
        "looked_in" => report.omarchy.candidates,
        "found" => report.omarchy.root
      },
      "disabled" => report.disabled,
      "disabled_not_found" => report.not_found,
      "diagnostics" => report.diagnostics
    }
  end

  defp json_entry(%{skill: skill} = entry) do
    %{
      "name" => Skill.qualified_name(skill),
      "description" => skill.description,
      "kind" => Atom.to_string(skill.kind),
      "state" => Atom.to_string(entry.state),
      "source" => source(skill.source),
      "from" => entry.from,
      "path" => skill.path,
      "real_path" => skill.real_path,
      "linked" => linked?(skill),
      "shadowed" =>
        Enum.map(entry.shadowed, fn shadow ->
          %{
            "from" => shadow.from,
            "source" => source(shadow.skill.source),
            "path" => shadow.skill.path,
            "real_path" => shadow.skill.real_path,
            "same_file" => shadow.same?
          }
        end)
    }
  end

  defp text(report) do
    skills =
      case report.skills do
        [] -> ["No skills were found."]
        entries -> Enum.flat_map(entries, &text_entry(&1, report.context))
      end

    lines =
      ["Skills for a session in #{shown(report.directory, report.context)}:", ""] ++
        skills ++
        [""] ++
        system_lines(report) ++
        not_found_lines(report.not_found) ++
        notice_lines(report.diagnostics)

    Enum.map_join(lines, "", &(Sanitize.visible(&1) <> "\n"))
  end

  defp text_entry(%{skill: skill} = entry, context) do
    path = shown_path(skill, skill.path, context)

    real =
      if linked?(skill),
        do: ["  real path #{shown(skill.real_path, context)}"],
        else: []

    shadows =
      Enum.map(entry.shadowed, fn %{skill: lost, same?: same?} ->
        shown = shown_path(lost, lost.path, context)
        if same?, do: "  also at #{shown} (same file)", else: "  overrides #{shown}"
      end)

    [
      "#{Skill.qualified_name(skill)} · #{state_text(entry.state)} · #{entry.from}",
      "  #{path}"
    ] ++ real ++ shadows
  end

  defp state_text(:enabled), do: "enabled"
  defp state_text(:disabled), do: "disabled in config"
  defp state_text(:user_only), do: "user-only (disable-model-invocation)"
  defp state_text(:model_only), do: "model-only (user-invocable: false)"

  defp state_text(:not_invocable),
    do: "not invocable (disable-model-invocation, user-invocable: false)"

  defp system_lines(%{personal?: false}),
    do: [
      "Personal and Omarchy skills: not read without a state directory " <>
        "(--config none, and no LMX_HOME)."
    ]

  defp system_lines(%{omarchy: %{enabled?: false}}),
    do: [~s|Omarchy skills: off ("skills": {"omarchy": false} in the config).|]

  defp system_lines(%{omarchy: %{root: root}, context: context}) when is_binary(root),
    do: ["Omarchy skills: on, read from #{shown(root, context)}."]

  defp system_lines(%{omarchy: %{candidates: candidates}, context: context}) do
    looked = Enum.map_join(candidates, ", ", &shown(&1, context))
    ["Omarchy skills: on, but none are installed here (looked in #{looked})."]
  end

  defp not_found_lines([]), do: []

  defp not_found_lines(names),
    do: ["Disabled in the config but not found: #{Enum.join(names, ", ")}."]

  defp notice_lines([]), do: []
  defp notice_lines(notes), do: ["", "Notices:" | Enum.map(notes, &("  " <> &1))]

  defp fail(message) do
    IO.puts(:stderr, "lmx skills: " <> Sanitize.visible(message))
    {:error, 1}
  end
end
