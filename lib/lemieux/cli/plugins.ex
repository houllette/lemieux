defmodule Lemieux.CLI.Plugins do
  @moduledoc """
  `lmx plugin install | list | remove` — saved plugin selections.

  Selecting a plugin is the decision to trust it
  (`Lemieux.Extensions.Workspace.Plugin`): its hooks run and its MCP servers
  start. `--plugin-dir` makes that decision for one session; `install` makes
  it for every session by saving the directory in the config file's
  `"plugin_dirs"`. A Git URL is cloned first, into `plugins/NAME` under the
  state directory, with a shallow clone that never runs anything from the
  repository. `remove` forgets the selection; files it cloned stay where
  they are, and it says where.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options
  alias Lemieux.Extensions.Workspace.Plugin

  @doc "Runs a `plugin` subcommand, printing what it did."
  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts \\ []) do
    case Options.parse(argv, command: :request) do
      {:ok, options} -> command(options.argv, options, opts)
      {:error, message} -> fail(message)
    end
  end

  defp command(["install", source], options, opts), do: install(source, options, opts)
  defp command(["list"], options, _opts), do: list(options)
  defp command(["remove", target], options, _opts), do: remove(target, options)

  defp command(_argv, _options, _opts),
    do:
      fail(
        "usage: lmx plugin install PATH|GIT-URL | lmx plugin list | lmx plugin remove NAME|PATH"
      )

  defp install(source, options, opts) do
    with {:ok, path} <- config_path(options),
         {:ok, root} <- fetch(source, options, opts),
         {:ok, plugin} <- Plugin.read(root),
         :ok <- Config.update(path, &add_dir(&1, root)) do
      IO.puts("Installed #{plugin.name} from #{root}. It is selected for every session.")
    else
      {:error, message} -> fail(message)
    end
  end

  defp fetch(source, options, opts) do
    local = Path.expand(source, Keyword.get_lazy(opts, :cwd, &File.cwd!/0))

    cond do
      File.dir?(local) -> {:ok, local}
      git_url?(source) -> clone(source, options, opts)
      true -> {:error, "#{source} is neither a plugin directory nor a Git URL"}
    end
  end

  defp git_url?(source),
    do:
      String.match?(source, ~r{^(https?://|ssh://|git@|file://)}) or
        String.ends_with?(source, ".git")

  defp clone(_url, %Options{host: %{state_dir: nil}}, _opts),
    do: {:error, "cloning a plugin needs a state directory; --config none has none"}

  defp clone(url, %Options{host: %{state_dir: dir}}, opts) do
    name = url |> String.trim_trailing("/") |> Path.basename(".git")
    target = Path.join([dir, "plugins", name])
    git = Keyword.get(opts, :git, &git/2)

    if File.exists?(target) do
      {:error,
       "#{target} already exists; lmx plugin remove #{name} first, or install that directory"}
    else
      File.mkdir_p!(Path.dirname(target))
      args = ["clone", "--depth", "1", "--quiet", "--", url, target]

      with :ok <- git.(args, env: [{"GIT_TERMINAL_PROMPT", "0"}]), do: {:ok, target}
    end
  end

  defp git(args, cmd_opts) do
    case System.cmd("git", args, [stderr_to_stdout: true] ++ cmd_opts) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, "git clone failed: #{String.trim(output)}"}
    end
  end

  defp add_dir(settings, root) do
    Map.update(settings, "plugin_dirs", [root], &Enum.uniq(&1 ++ [root]))
  end

  defp list(options) do
    dirs = Config.get(options.config, "plugin_dirs", [])
    selections = Config.get(options.config, "plugins", [])

    if dirs == [] and selections == [] do
      IO.puts("No plugins are saved. lmx plugin install PATH|GIT-URL adds one.")
    else
      Enum.each(dirs, &IO.puts(describe(&1)))
      Enum.each(selections, &IO.puts("#{&1} (from a marketplace)"))
    end
  end

  defp describe(root) do
    case Plugin.read(Path.expand(root)) do
      {:ok, plugin} -> "#{plugin.name}#{version(plugin.version)} · #{root}"
      {:error, reason} -> "#{root} · cannot be read: #{reason}"
    end
  end

  defp version(nil), do: ""
  defp version(version), do: " #{version}"

  defp remove(target, options) do
    dirs = Config.get(options.config, "plugin_dirs", [])

    case Enum.find(dirs, &(&1 == Path.expand(target) or plugin_name(&1) == target)) do
      nil ->
        fail("no saved plugin #{target}; lmx plugin list shows them")

      dir ->
        with {:ok, path} <- config_path(options),
             :ok <- Config.update(path, &Map.put(&1, "plugin_dirs", List.delete(dirs, dir))) do
          IO.puts("Removed #{target}. Its files remain in #{dir}.")
        else
          {:error, message} -> fail(message)
        end
    end
  end

  defp plugin_name(dir) do
    case Plugin.read(Path.expand(dir)) do
      {:ok, plugin} -> plugin.name
      _unreadable -> Path.basename(dir)
    end
  end

  defp config_path(options) do
    case Config.path(options.config) do
      nil -> {:error, "saving a plugin needs a config file; --config none has none"}
      path -> {:ok, path}
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 1}
  end
end
