defmodule ResearchExtension.SystemOne.LocalServerTest do
  # Asks a System One server you started yourself which source to open, over
  # the real wire, with the question `ResearchExtension.Discovery` builds: the
  # check that discovery's question is portable beyond TypeSafe's service. It
  # runs only when `LOCAL_SYSTEM_ONE_URL` names the server
  # (test/test_helper.exs excludes it otherwise), with
  # `LOCAL_SYSTEM_ONE_MODEL` naming the model and, if the server wants one,
  # `LOCAL_SYSTEM_ONE_KEY` the bearer token. Run against Ollama 0.35 (2026-10)
  # with both models it serves for /v1/systemone:
  #
  #     ollama pull clef-flash        # and nimble
  #     LOCAL_SYSTEM_ONE_URL=http://127.0.0.1:11434 LOCAL_SYSTEM_ONE_MODEL=clef-flash \
  #       LEMIEUX_EXTENSION_BASE=/path/to/lemieux MIX_ENV=test \
  #       mix test test/system_one/local_server_test.exs
  #
  # Discovery runs for real over the fixture pages — the default classifier,
  # Req and the fetch tool — with at most two pages, so the second question
  # also offers STOP. Which source a model prefers is its own judgement, so
  # the test asserts that every answer is a valid choice among the offered
  # keys with a distribution over them, and prints the choices.
  use ExUnit.Case, async: false

  alias Lemieux.Tools.WebFetch
  alias ResearchExtension.{Discovery, FixtureServer}

  @moduletag :local_system_one

  test "a locally served model chooses among the sources discovery offers" do
    url = System.fetch_env!("LOCAL_SYSTEM_ONE_URL")
    model = System.fetch_env!("LOCAL_SYSTEM_ONE_MODEL")

    {:ok, server} = FixtureServer.start(Path.expand("../../bench/fixtures/pages", __DIR__))
    on_exit(fn -> FixtureServer.stop(server) end)

    provider = %{
      name: "local",
      type: :endpoint,
      base_url: url,
      api_key: System.get_env("LOCAL_SYSTEM_ONE_KEY"),
      api_key_header: nil,
      headers: %{},
      model: model
    }

    options = Discovery.resolve(provider: provider, timeout_ms: 120_000)
    classify = Keyword.fetch!(options, :classify)
    owner = self()

    observed = fn request ->
      result = classify.(request)
      send(owner, {:asked, request, result})
      result
    end

    rows =
      for {page, title, snippet} <- [
            {"allotment-gardening", "Allotment gardening in September",
             "Lift maincrop potatoes and sow green manure."},
            {"tidepool-release-notes", "Tidepool — Release notes",
             "3.5.0: replay from a timestamp; per-partition lag."},
            {"tidepool-overview", "Tidepool — Overview",
             "Tidepool is a small message broker. Network: the TCP port it listens on."},
            {"tidepool-limits", "Tidepool — Limits",
             "Maximum message size, frame size and partition count."}
          ],
          do: %{
            "url" => "#{server.base_url}/#{page}.html",
            "title" => title,
            "snippet" => snippet
          }

    config = %{
      max_total_bytes: 2_097_152,
      top_k: 2,
      fetch: WebFetch.new(unsafe_allow_loopback_for_tests: true),
      hooks: [],
      cwd: File.cwd!()
    }

    question = "Which TCP port does Tidepool listen on by default?"

    assert {:ok, report} =
             Discovery.fetch(question, rows, Keyword.put(options, :classify, observed), config)

    asked = collect()
    assert asked != []
    assert length(asked) == report.classifier_attempts

    for {request, result} <- asked do
      criteria = request["questions"]["next"]["criteria"]
      assert map_size(criteria) in 2..26
      assert Enum.all?(Map.values(criteria), &is_binary/1)

      assert {:ok,
              %{
                "model" => ^model,
                "answers" => %{
                  "next" => %{
                    "choice" => choice,
                    "confidence" => confidence,
                    "probabilities" => probabilities
                  }
                }
              }} = result

      assert Map.has_key?(criteria, choice)
      assert MapSet.new(Map.keys(probabilities)) == MapSet.new(Map.keys(criteria))
      assert abs(Enum.sum(Map.values(probabilities)) - 1) <= 0.02
      assert is_number(confidence) and confidence >= 0 and confidence <= 1
    end

    # The second question, once a page is in hand, also offers STOP.
    assert asked |> List.last() |> elem(0) |> get_in(["questions", "next", "criteria", "STOP"])
    assert Enum.all?(report.decisions, &(&1["model"] == model))

    choices =
      Enum.map_join(report.decisions, "; ", fn decision ->
        "#{decision["choice"]} (#{decision["url"] || "STOP"}) at confidence " <>
          "#{Float.round(decision["confidence"] / 1, 3)} in #{decision["latency_ms"]} ms"
      end)

    IO.puts("\n#{model} at #{url}: #{choices}; stop reason #{report.stop_reason}")
  end

  defp collect do
    receive do
      {:asked, request, result} -> [{request, result} | collect()]
    after
      0 -> []
    end
  end
end
