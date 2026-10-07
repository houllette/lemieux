defmodule ResearchExtension do
  @moduledoc """
  A research composition that plans requested facts, searches and fetches
  sources, and requires a matching passage in a fetched page for each claim.

  The pipeline is ordinary functions around bounded
  `Lemieux.Agent.Session` calls (see `ResearchExtension.Pipeline`). Search goes
  through the `Lemieux.WebSearch.Backend` behaviour and pages through
  `Lemieux.Tools.WebFetch`, both invoked through `Lemieux.Tools.run/4` so a
  host's hooks apply to the pipeline's network calls exactly as they would
  inside a session. The host supplies the backend, the configured fetch tool,
  the provider and the model.

  The previous one-search path remains available as `research_mode: :simple`.
  In that mode a configured System One provider (`ResearchExtension.SystemOne`)
  enables source selection and bounded documentation-link discovery;
  `discovery: false` disables it.

  A completed observation carries the plain answer, the cited URLs, what was
  fetched (with byte counts and truncation flags) and what was skipped. A
  citation to a URL that was not fetched fails the run rather than reaching
  the caller as an answer: that is the one thing a grounded pipeline must
  never pass through.
  """

  @behaviour Lemieux.Agent

  alias ResearchExtension.Pipeline

  @pipeline_keys [
    :search,
    :fetch,
    :top_k,
    :max_total_bytes,
    :hooks,
    :discovery,
    :query_strategy,
    :research_mode,
    :plan,
    :compose
  ]

  @impl Lemieux.Agent
  @spec run(input :: Lemieux.Agent.input(), opts :: keyword()) :: Lemieux.Agent.result()
  def run(%{prompt: question, cwd: cwd, timeout_ms: timeout_ms}, opts) do
    {pipeline_opts, session_opts} = Keyword.split(opts, @pipeline_keys)
    pipeline_opts = pipeline_opts ++ [cwd: cwd, timeout_ms: timeout_ms, session: session_opts]

    case Pipeline.run(question, pipeline_opts) do
      {:ok, result} -> {:ok, completed(result)}
      {:error, reason} -> {:error, reason, failed(reason, Pipeline.empty_partial())}
      {:error, reason, partial} -> {:error, reason, failed(reason, partial)}
    end
  end

  defp completed(result) do
    (result.session || %{})
    |> Map.merge(%{
      "status" => "completed",
      "answer" => result.answer,
      "citations" => result.citations,
      "claims" => json_data(Map.get(result, :claims)),
      "fetched" => Enum.map(result.fetched, &fetched/1),
      "skipped" => Enum.map(result.skipped, &skipped/1),
      "discovery" => discovery(result.discovery)
    })
  end

  defp failed(reason, partial) do
    (partial.session || %{})
    |> Map.merge(%{
      "status" => "failed",
      "answer" => "",
      "reason" => inspect(reason),
      "raw_answer" => partial.raw_answer,
      "claims" => json_data(Map.get(partial, :claims)),
      "fetched" => Enum.map(partial.fetched, &fetched/1),
      "skipped" => Enum.map(partial.skipped, &skipped/1),
      "discovery" => discovery(partial.discovery)
    })
  end

  defp fetched(page),
    do: %{"url" => page.url, "bytes" => page.bytes, "truncated" => page.truncated?}

  defp skipped(entry), do: %{"url" => entry.url, "reason" => entry.reason}

  # Pipeline evidence uses atoms for Elixir callers; Agent observations are
  # recursively JSON data, so the same nested evidence needs string keys.
  defp discovery(nil), do: nil
  defp discovery(value), do: value |> JSON.encode!() |> JSON.decode!()

  defp json_data(nil), do: nil
  defp json_data(value), do: value |> JSON.encode!() |> JSON.decode!()
end
