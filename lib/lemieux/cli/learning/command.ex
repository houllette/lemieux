defmodule Lemieux.CLI.Learning.Command do
  @moduledoc false
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Learning.Loop
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Sanitize

  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts) do
    with {:ok, options} <- Options.parse(argv, command: :status),
         home when is_binary(home) <- options.host.state_dir,
         cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0),
         :ok <- action(options.argv, home, cwd),
         {:ok, info} <- Loop.inspect(home, cwd) do
      info = Map.put(info, "host_enabled", Config.get(options.config, "learning", true) != false)
      IO.puts(Sanitize.for_device(JSON.encode!(info), :stdio, opts[:terminal?]))
      :ok
    else
      nil -> error("Learning needs a writable personal state directory (LMX_HOME).", opts)
      {:error, reason} -> error("Learning unavailable: #{inspect(reason)}", opts)
    end
  end

  defp action([], _home, _cwd), do: :ok
  defp action(["inspect"], _home, _cwd), do: :ok
  defp action(["undo"], home, cwd), do: Loop.undo(home, cwd)
  defp action(["off"], home, cwd), do: Loop.set_enabled(home, cwd, false)
  defp action(["on"], home, cwd), do: Loop.set_enabled(home, cwd, true)
  defp action(_invalid, _home, _cwd), do: {:error, "use lmx learning [inspect|undo|off|on]"}

  defp error(message, opts) do
    IO.puts(:stderr, Sanitize.for_device(message, :stderr, opts[:terminal?]))
    {:error, 1}
  end
end
