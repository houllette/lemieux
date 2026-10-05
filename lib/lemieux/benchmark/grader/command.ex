defmodule Lemieux.Benchmark.Grader.Command do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A mechanical grader expressed as an executable and argument vector.

  Commands are never passed through a shell. Manifest authors can interpolate
  `{answer}`, `{cwd}` and `{task_id}` into individual arguments, but shell
  metacharacters remain ordinary text. The command still executes arbitrary
  code with the launching user's authority; see `SECURITY.md`.
  """

  alias Lemieux.Benchmark.Command
  alias Lemieux.Benchmark.Task

  @type t :: %__MODULE__{
          command: [String.t()],
          timeout_ms: pos_integer(),
          env: map(),
          max_output_bytes: pos_integer()
        }

  @enforce_keys [:command]
  defstruct [:command, timeout_ms: :timer.minutes(5), env: %{}, max_output_bytes: 1_000_000]

  @doc false
  @spec from_map(map() | nil) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{"command" => command} = map)
      when is_list(command) and command != [] do
    with :ok <- strings(command),
         {:ok, timeout_ms} <- positive(map, "timeout_ms", :timer.minutes(5)),
         {:ok, max_output} <- positive(map, "max_output_bytes", 1_000_000),
         {:ok, env} <- env(map) do
      {:ok,
       %__MODULE__{
         command: command,
         timeout_ms: timeout_ms,
         max_output_bytes: max_output,
         env: env
       }}
    end
  end

  def from_map(_map),
    do: {:error, "task grader.command must be a non-empty array of strings"}

  @doc "Runs the grader and returns a JSON-shaped verdict."
  @spec grade(grader :: t(), task :: Task.t(), answer :: String.t()) ::
          {:ok, map()} | {:error, term()}
  def grade(%__MODULE__{} = grader, %Task{} = task, answer) when is_binary(answer) do
    replacements = %{
      "{answer}" => answer,
      "{cwd}" => task.cwd,
      "{task_id}" => task.id
    }

    command = interpolate(grader.command, replacements)

    with {:ok, result} <-
           Command.run(command,
             cwd: task.cwd,
             env: grader.env,
             timeout: grader.timeout_ms,
             max_output_bytes: grader.max_output_bytes
           ) do
      {:ok,
       result
       |> Map.put("passed", result["exit_status"] == 0 and result["timed_out"] == false)
       |> Map.put("kind", "command")}
    end
  end

  defp interpolate(argv, replacements) do
    Enum.map(argv, fn argument ->
      Enum.reduce(replacements, argument, fn {placeholder, value}, expanded ->
        String.replace(expanded, placeholder, value)
      end)
    end)
  end

  defp strings(values) do
    if Enum.all?(values, &is_binary/1),
      do: :ok,
      else: {:error, "grader command arguments must be strings"}
  end

  defp positive(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, "grader #{key} must be a positive integer"}
    end
  end

  defp env(map) do
    case Map.get(map, "env", %{}) do
      env when is_map(env) -> {:ok, env}
      _invalid -> {:error, "grader env must be an object"}
    end
  end
end
