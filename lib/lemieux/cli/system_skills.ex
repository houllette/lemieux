defmodule Lemieux.CLI.SystemSkills do
  @moduledoc """
  Which system skill roots exist on this machine: today, Omarchy's.

  Omarchy (an Arch Linux distribution built around Hyprland) ships Agent
  Skills for the agents it supports — `omarchy` for customizing the
  desktop, `diagnose-crash` for a core dump — in
  `$OMARCHY_PATH/default/agents/skills`, and links them into
  `~/.claude/skills`, `~/.codex/skills` and `~/.agents/skills`. `lmx`
  reads Omarchy's directory itself, so a machine where nothing linked them
  for `lmx` still has them, and every update Omarchy installs is the next
  session's: the directory is read in place, never copied, because a copy
  would be a stale skill the first time Omarchy changed its own.

  Where the directory is: `$OMARCHY_PATH/default/agents/skills` when
  `OMARCHY_PATH` is set (Omarchy's own scripts read it from there), else
  the packaged install's `/usr/share/omarchy/default/agents/skills`, else
  an older install's `~/.local/share/omarchy/default/agents/skills` — the
  first of those that is a directory, and only that one: a machine with a
  packaged install and an old one left behind gets one set of skills.
  Everything is read only; nothing here writes to an Omarchy directory.

  The knowledge is the CLI host's, not the workspace extension's, which
  takes system roots as a plain list (`:system_skill_dirs` on
  `Lemieux.Extensions.Workspace.Discovery.discover/2`): an embedder on
  another distribution names its own, and the library names no
  distribution. `"skills": {"omarchy": false}` in the config file turns the
  Omarchy roots off.

  The environment, home directory and packaged location are options
  (`:env`, `:home`, `:packaged`), so a test describes a machine instead of
  reading the one it runs on.
  """

  alias Lemieux.CLI.Config

  @packaged "/usr/share/omarchy"
  @skills Path.join(["default", "agents", "skills"])

  @typedoc "What `report/2` found: whether Omarchy discovery is on, where it looked, what it uses."
  @type report :: %{
          omarchy: %{
            enabled?: boolean(),
            candidates: [Path.t()],
            root: Path.t() | nil
          }
        }

  @doc """
  The system skill roots discovery should read: Omarchy's, when it is
  installed and the config does not turn it off.
  """
  @spec roots(config :: Config.t() | nil, opts :: keyword()) :: [Path.t()]
  def roots(config, opts \\ []) when is_list(opts) do
    case report(config, opts) do
      %{omarchy: %{enabled?: true, root: root}} when is_binary(root) -> [root]
      _off_or_absent -> []
    end
  end

  @doc """
  Whether Omarchy discovery is on, the directories it looks in, in order,
  and the one it uses (`nil` when none is a directory, or when it is off —
  nothing is looked at then).
  """
  @spec report(config :: Config.t() | nil, opts :: keyword()) :: report()
  def report(config, opts \\ []) when is_list(opts) do
    candidates = omarchy_candidates(opts)
    enabled? = omarchy?(config)

    root = if enabled?, do: Enum.find(candidates, &File.dir?/1)

    %{omarchy: %{enabled?: enabled?, candidates: candidates, root: root}}
  end

  @doc """
  Where Omarchy's skills may be, in the order they are tried. An empty or
  blank `OMARCHY_PATH` is unset, as Omarchy's own scripts treat it.
  """
  @spec omarchy_candidates(opts :: keyword()) :: [Path.t()]
  def omarchy_candidates(opts \\ []) when is_list(opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    home = Keyword.get_lazy(opts, :home, fn -> Path.expand("~") end)
    packaged = Keyword.get(opts, :packaged, @packaged)

    explicit =
      case String.trim(Map.get(env, "OMARCHY_PATH") || "") do
        "" -> []
        path -> [path]
      end

    (explicit ++ [packaged, Path.join([home, ".local", "share", "omarchy"])])
    |> Enum.map(&Path.join(Path.expand(&1), @skills))
    |> Enum.uniq()
  end

  @doc """
  Whether the config leaves Omarchy discovery on: it is unless
  `"skills": {"omarchy": false}` says otherwise. `--config none` has no
  file to say so, and leaves it on; `lmx run --config none` reads no
  system skills anyway (`Lemieux.CLI.Skills.discovery_options/2`).
  """
  @spec omarchy?(config :: Config.t() | nil) :: boolean()
  def omarchy?(config), do: Map.get(Config.get(config, "skills", %{}), "omarchy", true) != false
end
