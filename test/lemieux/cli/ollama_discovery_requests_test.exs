defmodule Lemieux.CLI.OllamaDiscoveryRequestsTest do
  # What the terminal UI asks a local Ollama in one discovery
  # (`Lemieux.CLI.TUI.discovered_models/2`): `/api/tags` once. The list, the
  # tags without tools and the pick each asked for it again, three requests
  # for one answer, from a background task on every start.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Ollama
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.TUI

  @tags [
    %{"name" => "all-minilm:latest", "capabilities" => ["embedding"]},
    %{"name" => "gemma3:1b", "capabilities" => ["completion"]},
    %{"name" => "qwen3:8b", "capabilities" => ["completion", "tools"]}
  ]

  setup do
    {:ok, options} = Options.parse(["--config", "none"])
    %{options: options}
  end

  defp daemon do
    test = self()

    [
      get: fn url, _request ->
        send(test, {:get, url})
        {:ok, %Req.Response{status: 200, body: %{"models" => @tags}}}
      end,
      post: fn _url, request ->
        send(test, {:show, request[:json]["model"]})
        name = request[:json]["model"]
        tag = Enum.find(@tags, &(&1["name"] == name))
        {:ok, %Req.Response{status: 200, body: %{"capabilities" => tag["capabilities"]}}}
      end,
      recent: [],
      api_key: nil
    ]
  end

  defp gets do
    receive do
      {:get, url} -> [url | gets()]
    after
      0 -> []
    end
  end

  test "one discovery asks /api/tags once", %{options: options} do
    assert TUI.discovered_models(options, ollama: daemon()) == [{:preferred, "ollama:qwen3:8b"}]

    assert [tags] = gets()
    assert tags =~ "/api/tags"
    # The pick is still confirmed with `/api/show`, once.
    assert_received {:show, "qwen3:8b"}
    refute_received {:show, _another}
  end

  test "an answer already read is used as it is", %{options: options} do
    served = Ollama.served(options, daemon())
    assert [_tags] = gets()

    assert Ollama.models(options, Keyword.put(daemon(), :served, served)) == [
             "ollama:gemma3:1b",
             "ollama:qwen3:8b"
           ]

    assert {:ok, %{model: "ollama:qwen3:8b"}} =
             Ollama.local_model(options, Keyword.put(daemon(), :served, served))

    assert gets() == []

    # And it is the list the daemon would have been asked for.
    assert Ollama.models(options, daemon()) == ["ollama:gemma3:1b", "ollama:qwen3:8b"]
    assert Ollama.models(options, Keyword.put(daemon(), :served, :unreachable)) == []
  end
end
