defmodule Lemieux.Agent do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  An executable specialization of Lemieux, shared by hosts and benchmarks.

  Implement `c:run/2` with ordinary Elixir functions and `with` expressions.
  Deterministic selection and validation surround bounded model work through
  `Lemieux.Agent.Session`; there is no second agent loop or workflow DSL.
  Applications own branching, credentials, tools, isolation and cumulative
  budgets. Options are executable host configuration and are never serialized
  by this boundary. Adding an agent dependency starts no Lemieux process.

  Inputs contain only the prompt, workspace and timeout. Graders, expected
  answers and benchmark metadata are deliberately absent. This is an API
  separation, not filesystem isolation: untrusted code needs a host sandbox.

  A completed observation must say `"status" => "completed"` and supply a
  string `"answer"`. Failed observations retain their evidence but cannot be
  accepted merely because a final artifact happens to pass a grader. Usage
  must include every model-driven stage; missing cost remains unknown.
  """

  @type input :: %{prompt: String.t(), cwd: Path.t(), timeout_ms: pos_integer()}
  @type observation :: %{required(String.t()) => term()}
  @type result :: {:ok, observation()} | {:error, term()} | {:error, term(), observation()}

  @callback run(input :: input(), opts :: keyword()) :: result()

  @doc "Resolves a frozen, non-secret profile for isolated extension evaluation."
  @callback configure(profile :: map()) :: {:ok, keyword(), map()} | {:error, term()}
  @optional_callbacks configure: 1

  @doc "Executes an installed agent module with the same contract used for evaluation."
  @spec run(agent :: module(), input :: input(), opts :: keyword()) :: result()
  def run(agent, input, opts \\ [])

  def run(agent, %{prompt: prompt, cwd: cwd, timeout_ms: timeout} = input, opts)
      when is_atom(agent) and is_binary(prompt) and is_binary(cwd) and cwd != "" and
             is_integer(timeout) and timeout > 0 and is_list(opts) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :run, 2) do
      input
      |> Map.take([:prompt, :cwd, :timeout_ms])
      |> agent.run(opts)
      |> validate_result()
    else
      {:error, :invalid_agent_module}
    end
  end

  def run(_agent, _input, _opts), do: {:error, :invalid_agent_input}

  defp validate_result({:ok, %{"status" => "completed", "answer" => answer} = observation})
       when is_binary(answer),
       do: serializable_result({:ok, observation}, observation)

  defp validate_result({:ok, %{"status" => "failed"} = observation}),
    do: serializable_result({:error, :agent_failed, observation}, observation)

  defp validate_result({:error, _reason} = error), do: error

  defp validate_result({:error, _reason, observation} = error) when is_map(observation),
    do: serializable_result(error, observation)

  defp validate_result(_invalid), do: {:error, :invalid_agent_result}

  defp serializable_result(result, observation) do
    if json?(observation), do: result, else: {:error, :invalid_agent_observation}
  end

  defp json?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  defp json?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json?(item) end)

  defp json?(_value), do: false
end
