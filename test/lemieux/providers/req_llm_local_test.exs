defmodule Lemieux.Providers.ReqLLMLocalTest do
  @moduledoc """
  What the adapter does differently for a model an Ollama daemon the person
  runs serves, and what it leaves alone for every other model.

  Every "daemon" here is a loopback stub. The developer's own Ollama, if one
  is running, must not decide what these tests see.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider
  alias Lemieux.Request
  alias LemieuxTest.HTTPFixture

  @answer "data: " <>
            JSON.encode!(%{
              choices: [%{index: 0, delta: %{content: "hello"}, finish_reason: "stop"}]
            }) <> "\n\ndata: [DONE]\n\n"

  # A stub answering the chat request with `@answer` and `/api/ps` with
  # `loaded`, after `delay` milliseconds; every request it sees is sent to
  # the test as `{:asked, path, decoded_body}`.
  defp daemon(opts \\ []) do
    parent = self()
    delay = Keyword.get(opts, :delay, 0)
    loaded = Keyword.get(opts, :loaded, [])

    {url, listener, server} =
      HTTPFixture.server(
        fn path, _headers, body, _socket ->
          send(parent, {:asked, path, decoded(body)})
          Process.sleep(delay)

          if path == "/api/ps" do
            %{status: 200, headers: [], body: JSON.encode!(%{"models" => loaded})}
          else
            %{status: 200, headers: [{"content-type", "text/event-stream"}], body: @answer}
          end
        end,
        requests: Keyword.get(opts, :requests, 1)
      )

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    url
  end

  defp decoded(""), do: nil
  defp decoded(body), do: JSON.decode!(body)

  # The events a request emitted, in the order it emitted them.
  defp received_events(acc \\ []) do
    receive do
      {:event, event} -> received_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ask(provider, model, params \\ []) do
    parent = self()
    request = Request.new(model, entries: [Entry.new(:user, %{"text" => "hi"})], params: params)
    Provider.run(provider, request, &send(parent, {:event, &1}))
  end

  # The generated-token limit a body carries, whatever the wire calls it.
  defp output_limit(body),
    do: Enum.find_value(~w(max_tokens max_completion_tokens max_output_tokens), &body[&1])

  describe "a turn's output" do
    # Nothing else bounds one local answer: the stream-idle limit never fires
    # while tokens flow, and turn and request limits count requests. A local
    # model that fell into repeating itself wrote the same line 305 times
    # over fifteen minutes before anybody stopped it.
    test "is capped at 16,384 tokens for a local model" do
      url = daemon()
      provider = ReqLLMProvider.new(base_url: url, max_retries: 0, ollama_window: false)

      assert :ok = ask(provider, "ollama:gemma4:12b")
      assert_received {:asked, "/chat/completions", body}
      assert body["max_tokens"] == 16_384
    end

    # A self-hosted OpenAI-compatible server refuses a request whose prompt
    # plus `max_tokens` is more than its window holds, so 16,384 reserved
    # would make a 16k-window vLLM refuse every request; and its own default
    # is already the room the window has left. Neither the catalog nor this
    # adapter knows these models, and the cap is not theirs.
    test "is left to the server for a model only a local daemon is capped for" do
      for spec <- ["vllm:my-model", "lmstudio:qwen", "openai:gpt-9-ultra"] do
        url = daemon()
        provider = ReqLLMProvider.new(base_url: url, api_key: "test-key", max_retries: 0)

        _answered_or_not = ask(provider, spec)
        assert_received {:asked, _path, body}
        assert output_limit(body) == nil, "#{spec} was sent #{inspect(output_limit(body))}"
      end
    end

    test "is left to a host that routes local models elsewhere" do
      url = daemon()

      provider =
        ReqLLMProvider.new(
          max_retries: 0,
          api_key: "test-key",
          transport_routes: %{"ollama" => [provider: "openai", base_url: url]}
        )

      _answered_or_not = ask(provider, "ollama:gemma4:12b")
      assert_received {:asked, _path, body}
      assert output_limit(body) == nil
    end

    test "keeps a limit the request set itself" do
      url = daemon()
      provider = ReqLLMProvider.new(base_url: url, max_retries: 0, ollama_window: false)

      assert :ok = ask(provider, "ollama:gemma4:12b", max_tokens: 1_000)
      assert_received {:asked, "/chat/completions", body}
      assert body["max_tokens"] == 1_000
    end

    test "takes a host's own default, and sends none when the host says nil" do
      url = daemon()

      provider =
        ReqLLMProvider.new(
          base_url: url,
          max_retries: 0,
          ollama_window: false,
          local_max_tokens: 2_048
        )

      assert :ok = ask(provider, "ollama:gemma4:12b")
      assert_received {:asked, "/chat/completions", %{"max_tokens" => 2_048}}

      url = daemon()

      provider =
        ReqLLMProvider.new(
          base_url: url,
          max_retries: 0,
          ollama_window: false,
          local_max_tokens: nil
        )

      assert :ok = ask(provider, "ollama:gemma4:12b")
      assert_received {:asked, "/chat/completions", body}
      refute Map.has_key?(body, "max_tokens")
    end

    test "is left to the catalog when it publishes a limit" do
      {:ok, model} = ReqLLM.model("openai:gpt-4.1-mini")
      published = model.limits.output
      assert is_integer(published) and published != 16_384

      url = daemon()
      provider = ReqLLMProvider.new(base_url: url, api_key: "test-key", max_retries: 0)

      _answered_or_not = ask(provider, "openai:gpt-4.1-mini")
      assert_received {:asked, _path, body}
      assert output_limit(body) == published
    end
  end

  describe "a local model's first token" do
    # Ollama sends nothing while it reads a prompt, and a cold 27B model took
    # 324 seconds over a 32k-token one: past the five minutes lmx allows a
    # silent stream, so the request was abandoned at 29,928 of 29,929 tokens
    # and only a retry, served from the prefix cache, finished it.
    test "may take longer than a hosted model's before the stream counts as stalled" do
      opts = [
        max_retries: 0,
        ollama_window: false,
        receive_timeout: 200,
        stream_idle_timeout: 200,
        local_idle_timeout: 5_000
      ]

      url = daemon(delay: 800)
      local = ReqLLMProvider.new([base_url: url] ++ opts)

      assert :ok = ask(local, "ollama:gemma4:12b")
      assert_received {:event, {:text_delta, "hello"}}

      url = daemon(delay: 800)
      hosted = ReqLLMProvider.new([base_url: url, api_key: "test-key"] ++ opts)

      assert {:error, _stalled} = ask(hosted, "openai:gpt-4.1-mini")
    end
  end

  describe "the window a local daemon serves" do
    test "is what context_window/2 answers for a local model" do
      url = daemon(loaded: [%{"name" => "gemma4:12b", "context_length" => 8_192}])

      assert Provider.context_window(ReqLLMProvider.new(base_url: url), "ollama:gemma4:12b") ==
               8_192

      assert_received {:asked, "/api/ps", nil}
    end

    # Before, not after: `{:done, _}` is the last event a provider sends, and
    # a compaction summary whose last event is anything else is refused as
    # unfinished — every summary of a local session would have failed.
    test "is reported after each answer, before the answer ends" do
      url = daemon(requests: 2, loaded: [%{"name" => "gemma4:12b", "context_length" => 4_096}])
      provider = ReqLLMProvider.new(base_url: url, max_retries: 0)

      assert :ok = ask(provider, "ollama:gemma4:12b")

      events = received_events()
      assert List.last(events) == {:done, :stop}
      assert {:context_window, 4_096} in events
      assert_received {:asked, "/chat/completions", _body}
      assert_received {:asked, "/api/ps", nil}
    end

    test "is not asked for when the host turned the lookup off" do
      url = daemon(loaded: [%{"name" => "gemma4:12b", "context_length" => 8_192}])
      provider = ReqLLMProvider.new(base_url: url, ollama_window: false)

      assert Provider.context_window(provider, "ollama:gemma4:12b") == nil

      assert :ok = ask(provider, "ollama:gemma4:12b")
      refute_received {:event, {:context_window, _window}}
      refute_received {:asked, "/api/ps", _body}
    end

    test "is never asked of a hosted model" do
      url = daemon()
      provider = ReqLLMProvider.new(base_url: url)

      assert is_integer(Provider.context_window(provider, "anthropic:claude-haiku-4-5"))
      refute_received {:asked, _path, _body}
    end
  end
end
