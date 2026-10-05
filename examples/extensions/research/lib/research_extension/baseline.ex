defmodule ResearchExtension.Baseline do
  @moduledoc """
  The comparison baseline: the same bounded synthesis session asked the bare
  question, with no search, no fetch and no tools.

  The bench pairs this against `ResearchExtension` so that a difference in
  graded answers can only come from the pages the pipeline fetched. It is an
  ordinary `Lemieux.Agent`; a host has no reason to run it outside a bench.
  """

  @behaviour Lemieux.Agent

  alias Lemieux.Agent.Session

  @system "You answer research questions. Reply with only a JSON object of the form " <>
            "{\"answer\": \"<answer>\", \"citations\": []}."

  @impl Lemieux.Agent
  @spec run(input :: Lemieux.Agent.input(), opts :: keyword()) :: Lemieux.Agent.result()
  def run(input, opts) do
    session_options =
      opts
      |> Keyword.get(:session_options, [])
      |> Keyword.put(:tools, [])
      |> Keyword.put(:system, @system)
      |> Keyword.put_new(:max_turns, 1)

    with {:ok, observation} <-
           Session.run(input, Keyword.put(opts, :session_options, session_options)) do
      {:ok, Map.put(observation, "answer", plain_answer(observation["answer"]))}
    end
  end

  defp plain_answer(raw) when is_binary(raw) do
    case JSON.decode(String.trim(raw)) do
      {:ok, %{"answer" => answer}} when is_binary(answer) -> answer
      _other -> raw
    end
  end

  defp plain_answer(_raw), do: ""
end
