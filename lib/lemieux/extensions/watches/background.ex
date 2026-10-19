defmodule Lemieux.Extensions.Watches.Background do
  @moduledoc """
  Observes an already-running `Lemieux.Background` command.

  A vanished runtime is explicitly unavailable, never rerun. Background
  commands retain their existing owner lifetime; stopping a watch does not
  cancel them. For builds that must survive a VM exit, supply a durable
  external job source instead.
  """
  @behaviour Lemieux.Extensions.Watches.Source

  @impl true
  def validate(_state, %{"task_id" => id}) when is_binary(id) and byte_size(id) in 1..200,
    do: {:ok, %{"task_id" => id}}

  def validate(_state, _target), do: {:error, :invalid_background_target}

  @impl true
  def observe(state, %{"task_id" => id}) do
    case Lemieux.Background.poll(state.supervisor, state.session_id, id) do
      {:ok, %{status: :running}} ->
        {:pending, "Command is running."}

      {:ok, task} ->
        {:done,
         %{
           "outcome" => outcome(task),
           "summary" => "Command exit status: #{inspect(task.exit_status)}",
           "logs" => task.output,
           "run_id" => task.id
         }}

      {:error, :not_found} ->
        {:error, :unavailable, "Original command is unavailable; it was not restarted."}
    end
  end

  # `exited` describes process lifecycle, not whether its work succeeded.
  # Live failing commands otherwise had the same headline as successful ones.
  defp outcome(%{status: :exited, exit_status: 0}), do: "success"
  defp outcome(%{status: :exited}), do: "failure"
  defp outcome(task), do: Atom.to_string(task.status)
end
