defmodule Lemieux.Agent.Composition do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Bounded fan-out and accounting for checkpointed ordinary Elixir agents.

  This is neither a scheduler nor another agent loop. Hosts choose the finite
  input list, isolation, per-stage request/cost allowances and control flow.
  Use distinct checkpoint keys for independent steps. Timeout kills a worker;
  its persisted intent remains uncertain until the host reconciles its effects.
  Outcomes retain input order and every failure; successful siblings are not
  discarded when one worker fails.
  """
  alias Lemieux.Agent
  alias Lemieux.Agent.Checkpoint
  alias Lemieux.Agent.Session, as: AgentSession
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Usage

  @doc "Runs a request-bounded ordinary session and keeps its transcript reference instead of embedding its full log."
  @spec session(input :: Agent.input(), opts :: keyword()) :: Agent.result()
  def session(input, opts) do
    limit = opts |> Keyword.get(:session_options, []) |> Keyword.get(:max_requests)

    if is_integer(limit) and limit > 0 do
      case Agent.run(AgentSession, input, opts) do
        {:ok, observation} -> {:ok, Map.delete(observation, "transcript")}
        {:error, reason, observation} -> {:error, reason, Map.delete(observation, "transcript")}
        error -> error
      end
    else
      {:error, :stage_request_limit_required}
    end
  end

  @doc "Runs a finite batch with explicit concurrency and time limits, returning all outcomes."
  @spec parallel(
          supervisor :: atom(),
          items :: list(),
          fun :: (term() -> term()),
          opts :: keyword()
        ) :: list()
  def parallel(supervisor, items, fun, opts)
      when is_list(items) and length(items) <= 64 and is_function(fun, 1) do
    concurrency = Keyword.fetch!(opts, :max_concurrency)
    timeout = Keyword.fetch!(opts, :timeout)

    unless concurrency in 1..8 and is_integer(timeout) and timeout > 0,
      do: raise(ArgumentError, "composition requires concurrency 1..8 and a positive timeout")

    Sup.task_supervisor(supervisor)
    |> Task.Supervisor.async_stream_nolink(items, fun,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.to_list()
  end

  @doc "Sums all supplied step attempts, including failed/retried observations; unknown cost stays unknown."
  @spec usage(handle :: Checkpoint.t(), keys :: [String.t()]) :: map()
  def usage(handle, keys) do
    keys
    |> Enum.uniq()
    |> Enum.flat_map(fn key ->
      case Checkpoint.status(handle, key) do
        {:ok, %{value: %{"attempts" => attempts} = current}} ->
          Enum.map(attempts ++ [current], &attempt_usage/1)

        _unknown ->
          [%{"cost_usd" => nil}]
      end
    end)
    |> Usage.sum()
  end

  defp attempt_usage(%{"status" => status}) when status in ["ready", "awaiting_approval"],
    do: Usage.empty()

  defp attempt_usage(%{"output" => %{"usage" => usage}}) when is_map(usage), do: usage
  defp attempt_usage(_unmeasured), do: %{"cost_usd" => nil}
end
