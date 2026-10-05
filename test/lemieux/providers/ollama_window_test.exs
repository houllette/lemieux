defmodule Lemieux.Providers.OllamaWindowTest do
  @moduledoc """
  What a local Ollama daemon says about the window it gives a model.

  Every daemon here is a stub on a loopback port: the developer's own Ollama,
  if one is running, must not decide what these tests see, and nothing here
  may load a model into it.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Providers.OllamaWindow
  alias LemieuxTest.HTTPFixture

  # A daemon answering each path from `routes`, for as many requests as given.
  defp daemon(routes, requests \\ 1) do
    parent = self()

    {url, listener, server} =
      HTTPFixture.server(
        fn path, _headers, body, _socket ->
          send(parent, {:asked, path, body})

          case Map.fetch(routes, path) do
            {:ok, {status, {:raw, raw}}} ->
              %{status: status, headers: [], body: raw}

            {:ok, {status, payload}} ->
              %{status: status, headers: [], body: JSON.encode!(payload)}

            :error ->
              %{status: 404, headers: [], body: ~s({"error":"not found"})}
          end
        end,
        requests: requests
      )

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    url
  end

  defp ps(models), do: {200, %{"models" => models}}

  defp loaded(name, context_length),
    do: %{"name" => name, "model" => name, "context_length" => context_length}

  defp show(parameters, trained) do
    {200,
     %{
       "parameters" => parameters,
       "model_info" => %{"general.architecture" => "gemma4", "gemma4.context_length" => trained}
     }}
  end

  describe "the native API's address" do
    test "is the OpenAI-compatible base without its /v1" do
      assert OllamaWindow.native_base("http://localhost:11434/v1") == "http://localhost:11434"
      assert OllamaWindow.native_base("http://localhost:11434/v1/") == "http://localhost:11434"
      assert OllamaWindow.native_base("http://localhost:11434") == "http://localhost:11434"
      assert OllamaWindow.native_base("http://box:8080/ollama/v1") == "http://box:8080/ollama"
    end
  end

  describe "a model the daemon has loaded" do
    test "has the window /api/ps reports for it" do
      url = daemon(%{"/api/ps" => ps([loaded("gemma4:12b", 4_096)])})

      assert OllamaWindow.loaded(url <> "/v1", "gemma4:12b") == 4_096
      assert_received {:asked, "/api/ps", _body}
    end

    test "is found under its :latest tag when it was named without one" do
      url = daemon(%{"/api/ps" => ps([loaded("llama3:latest", 8_192)])})

      assert OllamaWindow.loaded(url, "llama3") == 8_192
    end

    test "is not confused with another loaded model" do
      url = daemon(%{"/api/ps" => ps([loaded("qwen3:14b", 40_960)])})

      assert OllamaWindow.loaded(url, "gemma4:12b") == nil
    end
  end

  describe "a model the daemon has not loaded" do
    test "has no served window yet" do
      url = daemon(%{"/api/ps" => ps([])})

      assert OllamaWindow.loaded(url, "gemma4:12b") == nil
    end

    test "will load with its Modelfile's num_ctx, never past what it was trained on" do
      parameters = "num_ctx                        32768\ntemperature                    1"
      url = daemon(%{"/api/show" => show(parameters, 16_384)})

      assert OllamaWindow.configured(url, "gemma4:12b") == 16_384
      assert_received {:asked, "/api/show", body}
      assert JSON.decode!(body) == %{"model" => "gemma4:12b"}

      url = daemon(%{"/api/show" => show("num_ctx 8192", 262_144)})
      assert OllamaWindow.configured(url, "gemma4:12b") == 8_192
    end

    # The trained length is a ceiling, not the window: the daemon sizes the
    # window from its own settings when the model loads, and nothing in the
    # API says what those are until it has.
    test "with no num_ctx says nothing before it loads" do
      url = daemon(%{"/api/show" => show("top_k 64\ntemperature 1", 262_144)})

      assert OllamaWindow.configured(url, "gemma4:12b") == nil
    end
  end

  describe "window/2" do
    test "prefers what is loaded" do
      url = daemon(%{"/api/ps" => ps([loaded("gemma4:12b", 32_768)])})

      assert OllamaWindow.window(url, "gemma4:12b") == 32_768
      refute_received {:asked, "/api/show", _body}
    end

    test "falls back to the Modelfile when nothing is loaded" do
      url = daemon(%{"/api/ps" => ps([]), "/api/show" => show("num_ctx 8192", 131_072)}, 2)

      assert OllamaWindow.window(url, "gemma4:12b") == 8_192
    end
  end

  describe "an endpoint that cannot say" do
    test "is not Ollama: nothing is known" do
      url = daemon(%{}, 2)

      assert OllamaWindow.window(url, "gemma4:12b") == nil
    end

    test "answers something else at /api/ps: nothing is known" do
      url = daemon(%{"/api/ps" => {200, %{"unexpected" => true}}})

      assert OllamaWindow.loaded(url, "gemma4:12b") == nil
    end

    test "answers JSON that does not parse: nothing is known" do
      url = daemon(%{"/api/ps" => {200, {:raw, "{\"models\": ["}}})
      assert OllamaWindow.loaded(url, "gemma4:12b") == nil

      url = daemon(%{"/api/show" => {200, {:raw, "<html>not ollama</html>"}}})
      assert OllamaWindow.configured(url, "gemma4:12b") == nil
    end

    # A host's base URL the HTTP client cannot use makes it raise or exit
    # rather than return an error; the session asking at start, and the
    # request the lookup follows, must not go down with it.
    test "is an address the HTTP client cannot use: nothing is known, nothing raises" do
      assert OllamaWindow.window("localhost:11434/v1", "gemma4:12b") == nil
      assert OllamaWindow.window("http://127.0.0.1:99999/v1", "gemma4:12b") == nil
    end

    test "is not listening: nothing is known" do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      assert OllamaWindow.window("http://127.0.0.1:#{port}/v1", "gemma4:12b") == nil
    end
  end
end
