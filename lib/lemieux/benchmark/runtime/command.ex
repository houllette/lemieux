defmodule Lemieux.Benchmark.Runtime.Command do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Runs a benchmark task through any command-line harness.

  The command is supplied by the caller, not built into Lemieux. That keeps
  subscription authentication, vendor flags and CLI-version policy in the host
  that owns them. Arguments may contain `{prompt}`, `{cwd}` and `{task_id}`.
  They are passed as an argv vector without a shell.
  """

  @behaviour Lemieux.Benchmark.Runtime

  alias Lemieux.Benchmark.Command
  alias Lemieux.Benchmark.Task

  @impl Lemieux.Benchmark.Runtime
  def run(%Task{} = task, opts) do
    with {:ok, argv} <- command(opts) do
      replacements = %{
        "{prompt}" => task.prompt,
        "{cwd}" => task.cwd,
        "{task_id}" => task.id
      }

      argv = interpolate(argv, replacements)

      with {:ok, result} <-
             Command.run(argv,
               cwd: task.cwd,
               env: Keyword.get(opts, :env, %{}),
               timeout: Keyword.get(opts, :timeout_ms, task.timeout_ms),
               max_output_bytes: Keyword.get(opts, :max_output_bytes, 1_000_000)
             ) do
        {:ok,
         %{
           "status" => status(result),
           "answer" => result["output"],
           "exit_status" => result["exit_status"],
           "timed_out" => result["timed_out"],
           "duration_ms" => result["duration_ms"],
           "command" => result["command"],
           "usage" => nil
         }}
      end
    end
  end

  defp command(opts) do
    case Keyword.get(opts, :command) do
      command when is_list(command) and command != [] ->
        if Enum.all?(command, &is_binary/1),
          do: {:ok, command},
          else: {:error, :command_arguments_must_be_strings}

      _missing ->
        {:error, :command_required}
    end
  end

  defp interpolate(argv, replacements) do
    Enum.map(argv, fn argument ->
      Enum.reduce(replacements, argument, fn {placeholder, value}, expanded ->
        String.replace(expanded, placeholder, value)
      end)
    end)
  end

  defp status(%{"timed_out" => true}), do: "timed_out"
  defp status(%{"exit_status" => 0}), do: "completed"
  defp status(_result), do: "failed"
end
