defmodule Lemieux.WebSearchSessionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools.WebSearch
  alias Lemieux.WebSearch.Result

  @moduletag :tmp_dir

  defmodule Backend do
    @moduledoc false
    @behaviour Lemieux.WebSearch.Backend

    @impl Lemieux.WebSearch.Backend
    def search(test_pid, query, _opts) do
      send(test_pid, {:searched, query})

      {:ok, [%Result{title: "Result", url: "https://example.com", snippet: "A result."}],
       %{"requests" => 1, "cost_usd" => 0.005}}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    supervisor = :"lemieux_web_search_session_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    %{supervisor: supervisor, store: JSONL.new(tmp_dir)}
  end

  test "refuses a paid search before it can cross the session cost cap", context do
    search = search_tool(self())

    provider =
      Scripted.new(
        [
          [
            {:usage, %{"input_tokens" => 5, "output_tokens" => 1, "cost_usd" => 0.001}},
            {:tool_call, call("search-1")},
            {:done, :tool_calls}
          ],
          [{:done, :stop}]
        ],
        estimated_cost_usd: 0.001
      )

    {:ok, session} = start_session(context, provider, search, 0.004)
    :ok = Session.prompt(session, "search")

    # Two provider round trips and a refused tool call in between, so this
    # waits on a whole turn rather than on one event. The suite-wide default
    # is sized for a single hop and this occasionally lost against it.
    assert_receive {:lemieux, _, {:finished, :stop}}, 5_000
    refute_received {:searched, _query}

    result =
      session
      |> Session.snapshot()
      |> Map.fetch!(:entries)
      |> Enum.find(&(&1.type == :tool_result))

    assert %Entry{payload: %{"outcome" => "budget", "error" => true}} = result
    assert result.payload["output"] =~ "would exceed"
  end

  test "persists search cost, includes it in spend and gates the following model request",
       context do
    search = search_tool(self())

    provider =
      Scripted.new(
        [
          [
            {:usage, %{"input_tokens" => 5, "output_tokens" => 1, "cost_usd" => 0.001}},
            {:tool_call, call("search-1")},
            {:done, :tool_calls}
          ],
          [{:done, :stop}]
        ],
        estimated_cost_usd: 0.002
      )

    {:ok, session} = start_session(context, provider, search, 0.007)
    :ok = Session.prompt(session, "search")

    assert_receive {:searched, "current Elixir docs"}

    assert_receive {:lemieux, _,
                    {:finished, {:budget, %{spent: spent, estimate: 0.002, cap: 0.007}}}}

    assert_in_delta spent, 0.006, 1.0e-12
    assert length(Scripted.requests(provider)) == 1

    snapshot = Session.snapshot(session)
    assert_in_delta snapshot.spent_usd, 0.006, 1.0e-12

    result = Enum.find(snapshot.entries, &(&1.type == :tool_result))
    assert result.payload["cost"] == %{"usd" => 0.005}
    assert result.payload["metadata"]["usage"]["requests"] == 1
  end

  defp search_tool(test_pid) do
    WebSearch.new(
      backend: {Backend, test_pid},
      max_results: 5,
      max_output_bytes: 12_000,
      max_cost_usd: 0.005
    )
  end

  defp call(id) do
    %{id: id, name: "web_search", arguments: %{"query" => "current Elixir docs"}}
  end

  defp start_session(context, provider, search, max_cost_usd) do
    Lemieux.start_session(
      supervisor: context.supervisor,
      provider: provider,
      store: context.store,
      model: "test:model",
      subscriber: self(),
      tools: [search],
      max_cost_usd: max_cost_usd
    )
  end
end
