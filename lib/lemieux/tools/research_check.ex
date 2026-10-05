defmodule Lemieux.Tools.ResearchCheck do
  @moduledoc """
  Checks research passages against this session's successful page fetches.

  A source URL alone is only proof that a page was opened. This tool reads the
  session's recorded `web_fetch` results and checks that each quoted passage
  appears in the corresponding fetched text. It makes no network or model
  request and cannot establish whether a passage logically entails the claim.
  The agent still has to list every requested fact and interpret the source.

  The check uses the bounded text that the fetch tool retained in the
  transcript. A passage omitted by extraction or truncation is unresolved,
  even if it might exist on the original page. That conservative result keeps
  an unfetched or unseen assertion from looking verified.
  """

  @behaviour Lemieux.Tool

  alias Lemieux.Entry
  alias Lemieux.Session
  alias Lemieux.Tool.Result

  @max_claims 10
  @max_fact_chars 300
  @max_passage_chars 700

  @impl true
  def name, do: "research_check"

  @impl true
  def description do
    """
    Before finishing multi-part web research, submit every requested fact with
    its fetched URL and a short verbatim supporting passage. This checks the
    passage against successful web_fetch results in this session; use focused
    web_search and web_fetch calls for any unresolved fact. A matching passage
    establishes source presence, not the truth of your interpretation.
    """
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "claims" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_claims,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "fact" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_fact_chars},
              "url" => %{"type" => "string", "minLength" => 1, "maxLength" => 2_048},
              "passage" => %{
                "type" => "string",
                "minLength" => 16,
                "maxLength" => @max_passage_chars
              }
            },
            "required" => ["fact", "url", "passage"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["claims"],
      "additionalProperties" => false
    }
  end

  @impl true
  def metadata do
    %{
      effects: %{class: "read", resource_types: ["session_transcript"], idempotent: true},
      runtime: %{timeout_ms: 10_000, max_output_bytes: 8_192, concurrency: %{class: "exclusive"}}
    }
  end

  @impl true
  def parallel_safe?, do: false

  @impl true
  def read_only?, do: true

  @impl true
  @spec run(args :: Lemieux.Tool.args(), context :: Lemieux.Tool.context()) ::
          {:ok, Result.t()} | {:error, String.t()}
  def run(%{"claims" => claims}, %{session: session})
      when is_list(claims) and length(claims) in 1..@max_claims and is_pid(session) do
    if Enum.all?(claims, &valid_claim?/1) do
      sources = session |> Session.snapshot() |> Map.fetch!(:entries) |> fetched_sources()

      checks =
        claims
        |> Enum.with_index(1)
        |> Enum.map(fn {claim, index} -> check(claim, index, sources) end)

      found = Enum.count(checks, &(&1["status"] == "passage_found"))
      summary = "Research passages found in fetched pages: #{found}/#{length(checks)}"

      {:ok,
       Result.new(summary,
         structured_content: %{
           "all_passages_found" => found == length(checks),
           "checks" => checks
         }
       )}
    else
      {:error, "research_check needs 1 to 10 claims with a fact, fetched URL and passage"}
    end
  end

  def run(_args, _context),
    do: {:error, "research_check needs 1 to 10 claims in an active session"}

  defp valid_claim?(%{"fact" => fact, "url" => url, "passage" => passage})
       when is_binary(fact) and is_binary(url) and is_binary(passage) do
    String.length(String.trim(fact)) in 1..@max_fact_chars and
      String.length(String.trim(url)) in 1..2_048 and
      String.length(normalize(passage)) in 16..@max_passage_chars
  end

  defp valid_claim?(_), do: false

  defp fetched_sources(entries) do
    for %Entry{type: :tool_result, payload: payload} <- entries,
        payload["name"] == "web_fetch",
        payload["error"] == false,
        content = payload["structured_content"] || %{},
        is_map(content),
        text = content["text"] || payload["output"],
        is_binary(text) do
      %{
        urls: [content["url"], content["requested_url"], get_in(payload, ["arguments", "url"])],
        text: normalize(text)
      }
    end
  end

  defp check(claim, index, sources) do
    candidates = Enum.filter(sources, &(claim["url"] in &1.urls))

    status =
      cond do
        candidates == [] ->
          "url_not_fetched"

        Enum.any?(candidates, &String.contains?(&1.text, normalize(claim["passage"]))) ->
          "passage_found"

        true ->
          "passage_not_found"
      end

    %{
      "index" => index,
      "fact" => claim["fact"],
      "url" => claim["url"],
      "status" => status
    }
  end

  defp normalize(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
