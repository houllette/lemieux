defmodule Lemieux.Tools.FileOps do
  @moduledoc """
  Deleting a file through a session's environment.

  `Lemieux.Environment` has read, write and list callbacks and no delete,
  and two things need one: `apply_patch`'s `*** Delete File` and `*** Move
  to`, and `Lemieux.Checkpoint` removing a file the agent created when a turn
  is undone. Both must delete *where the environment's files are*, which for
  a container or a sandbox is not this VM's filesystem.

  So an environment that implements the optional
  `c:Lemieux.Environment.delete_file/3` is asked directly (`Lemieux.Environment.Local`
  does), and any other gets `rm -f -- path` through its own command
  runner, after the same symlink-aware confinement check
  `Lemieux.Environment.Local` applies to reads and writes. Deleting with
  `File.rm/1` here instead would work for the local environment and silently
  delete the wrong file, or nothing, everywhere else.
  """

  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Tools.Search.Command

  @doc "Deletes the file at `path`, relative to `cwd`, through `environment`."
  @spec delete(environment :: Environment.t(), cwd :: Path.t(), path :: String.t()) ::
          :ok | {:error, term()}
  def delete(environment, cwd, path) when is_binary(path) do
    case Environment.delete_file(environment, cwd, path) do
      {:error, :unsupported} ->
        with {:ok, absolute} <- confined(cwd, path), do: remove(environment, cwd, absolute)

      result ->
        normalize(result)
    end
  end

  # `Lemieux.Environment.delete_file/3` answers `:ok` or an error.
  defp normalize(:ok), do: :ok
  defp normalize({:error, _reason} = error), do: error

  # The local environment's own rule, so a path `write` would refuse is one
  # this refuses to delete.
  defp confined(cwd, path) do
    case Local.confined(cwd, path) do
      {:ok, ^cwd} -> {:error, :eisdir}
      {:ok, absolute} -> {:ok, absolute}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove(environment, cwd, absolute) do
    command = "rm -f -- " <> Command.quote_argument(absolute)

    case Command.run(environment, cwd, command, timeout_ms: 10_000) do
      {:ok, %{status: 0}} -> :ok
      {:ok, %{status: status, output: output}} -> {:error, {:rm, status, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
