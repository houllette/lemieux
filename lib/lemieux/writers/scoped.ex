defmodule Lemieux.Writers.Scoped do
  @moduledoc false
  @behaviour Lemieux.Environment
  alias Lemieux.Checkpoint.Git
  alias Lemieux.Environment
  alias Lemieux.Writers.Plan

  @impl true
  def read_file(state, cwd, path), do: Environment.read_file(state.environment, cwd, path)
  @impl true
  def list_dir(state, cwd, path), do: Environment.list_dir(state.environment, cwd, path)
  @impl true
  def stream_file(state, cwd, path), do: Environment.stream_file(state.environment, cwd, path)
  @impl true
  def credentials(state), do: Environment.credentials(state.environment)

  @impl true
  def write_file(state, cwd, path, content) do
    with :ok <- permitted(state, cwd, path),
         do: Environment.write_file(state.environment, cwd, path, content)
  end

  @impl true
  def delete_file(state, cwd, path) do
    with :ok <- permitted(state, cwd, path),
         do: Environment.delete_file(state.environment, cwd, path)
  end

  @impl true
  def run(%{commands?: true} = state, command, opts),
    do: Environment.run(state.environment, command, opts)

  def run(state, _command, _opts), do: violation(state, :commands_not_granted)

  defp permitted(state, cwd, path) do
    relative = Path.relative_to(Path.expand(path, cwd), state.cwd)

    cond do
      cwd != state.cwd or not Plan.owns?(state.plan, relative) ->
        violation(state, {:outside_writer_scope, path})

      symbolic_local_path?(state, relative) ->
        violation(state, :symbolic_writer_path)

      true ->
        :ok
    end
  end

  defp symbolic_local_path?(%{environment: {Environment.Local, _}} = state, relative),
    do: symbolic_path?(state.cwd, relative)

  defp symbolic_local_path?(%{environment: Environment.Local} = state, relative),
    do: symbolic_path?(state.cwd, relative)

  defp symbolic_local_path?(_state, _relative), do: false

  defp symbolic_path?(cwd, relative) do
    Git.beyond_link?(cwd, relative) or
      match?({:ok, %{type: :symlink}}, File.lstat(Path.join(cwd, relative)))
  end

  defp violation(state, reason) do
    send(state.coordinator, {:writer_violation, state.plan.id, reason})
    {:error, reason}
  end
end
