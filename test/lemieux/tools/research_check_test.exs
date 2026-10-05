defmodule Lemieux.Tools.ResearchCheckTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.ResearchCheck

  @moduletag :tmp_dir
  @url "https://example.org/docs/release"

  defmodule FetchedPage do
    @behaviour Lemieux.Tool

    @impl true
    def name, do: "web_fetch"
    @impl true
    def description, do: "Fixture page fetch"
    @impl true
    def schema,
      do: %{
        "type" => "object",
        "properties" => %{"url" => %{"type" => "string"}},
        "required" => ["url"]
      }

    @impl true
    def parallel_safe?, do: true
    @impl true
    def read_only?, do: false

    @impl true
    def run(%{"url" => url}, _context) do
      {:ok,
       Result.new("Version 1.36 changed the Workload API to v1alpha2.",
         structured_content: %{
           "url" => url,
           "requested_url" => url
         }
       )}
    end
  end

  test "checks every passage against actual successful fetch receipts", %{tmp_dir: dir} do
    supervisor = :"research_check_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    provider =
      Scripted.new([
        [
          {:tool_call, %{id: "fetch-1", name: "web_fetch", arguments: %{"url" => @url}}},
          {:done, :tool_calls}
        ],
        [
          {:tool_call,
           %{
             id: "check-1",
             name: "research_check",
             arguments: %{
               "claims" => [
                 %{
                   "fact" => "The 1.36 API version",
                   "url" => @url,
                   "passage" => "Workload API to v1alpha2"
                 }
               ]
             }
           }},
          {:done, :tool_calls}
        ],
        Scripted.complete("done")
      ])

    assert {:ok, session} =
             Lemieux.start_session(
               supervisor: supervisor,
               provider: provider,
               store: JSONL.new(dir),
               model: "test:model",
               subscriber: self(),
               tools: [FetchedPage, ResearchCheck]
             )

    :ok = Session.prompt(session, "Check the 1.36 Workload API")
    assert_receive {:lemieux, _, {:finished, :stop}}, 5_000

    receipt =
      session
      |> Session.snapshot()
      |> Map.fetch!(:entries)
      |> Enum.find(&(&1.type == :tool_result and &1.payload["name"] == "research_check"))

    assert receipt.payload["structured_content"]["all_passages_found"] == true

    assert Tool.descriptor(ResearchCheck).identity["name"] == "research_check"

    claims = [
      %{
        "fact" => "The 1.36 API version",
        "url" => @url,
        "passage" => "Workload API to v1alpha2"
      },
      %{
        "fact" => "A claim absent from the page",
        "url" => @url,
        "passage" => "Workload API remained at v1alpha1"
      },
      %{
        "fact" => "A page never fetched",
        "url" => "https://example.org/docs/other",
        "passage" => "This passage was never fetched by the session"
      }
    ]

    assert {:ok, result} = ResearchCheck.run(%{"claims" => claims}, %{session: session})
    assert result.structured_content["all_passages_found"] == false

    assert Enum.map(result.structured_content["checks"], & &1["status"]) == [
             "passage_found",
             "passage_not_found",
             "url_not_fetched"
           ]
  end

  test "refuses a check without an active session or usable claims" do
    assert {:error, message} = ResearchCheck.run(%{"claims" => []}, %{})
    assert message =~ "active session"
  end
end
