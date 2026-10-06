defmodule Lemieux.Providers.ReqLLMStreamTest do
  # Wire-level behaviour of the adapter against a local HTTP fixture: what a
  # request carries, and what a stream that ends badly becomes. No network.
  use ExUnit.Case, async: true

  alias Lemieux.{Entry, Provider, Request}
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Provider.Interrupted
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias LemieuxTest.HTTPFixture

  defmodule FixtureTool do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl true
    def name, do: "fixture_tool"

    @impl true
    def description, do: "A tool whose schema has required and optional properties."

    @impl true
    def schema do
      %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string"},
          "task_id" => %{"type" => "string"},
          "note" => %{"type" => "string"},
          "label" => %{"type" => "string"}
        },
        "required" => ["label"]
      }
    end

    @impl true
    def run(_args, _context), do: {:ok, "ran"}
  end

  describe "Anthropic prompt caching" do
    test "a direct stream reports realtime cost when the catalog also has batch pricing" do
      owner = self()
      provider = anthropic(owner, 200, sse(complete_answer("Priced.")))

      assert :ok = Provider.run(provider, claude_request(), &send(owner, &1))
      assert_receive {:usage, usage}
      assert usage["pricing"]["status"] == "priced"

      assert_in_delta usage["total_cost"],
                      (usage["input_tokens"] + usage["output_tokens"] * 5) / 1_000_000,
                      1.0e-10
    end

    test "a stream preserves explicitly incomplete pricing context, and is priced at list rates" do
      # The context reaches ReqLLM untouched — it cannot price the request
      # with it — and the adapter prices the usage at the model's list rates,
      # saying so, rather than leaving the session's spend unknown.
      owner = self()
      provider = anthropic(owner, 200, sse(complete_answer("Unpriced.")))
      request = claude_request(params: [pricing_context: %{}])

      assert :ok = Provider.run(provider, request, &send(owner, &1))
      assert_receive {:usage, usage}
      assert usage["pricing"]["status"] == "list_rates"
      assert usage["total_cost"] == nil

      assert_in_delta usage["cost_usd"],
                      (usage["input_tokens"] + usage["output_tokens"] * 5) / 1_000_000,
                      1.0e-10

      assert Lemieux.Usage.cost_usd(usage) == usage["cost_usd"]
    end

    test "a direct stream to a model whose tariff ReqLLM cannot resolve is priced at list rates" do
      # gpt-6-luna's tariff has service-tier modifiers no context resolves, so
      # ReqLLM reports its usage unpriced; under a dollar cap that left the
      # session's spend unknown after the first answer. See the matching
      # estimate test in ReqLLMTest for when to move this to another model.
      owner = self()
      model = "openai:gpt-6-luna"
      {:ok, %{cost: %{input: input_rate, output: output_rate}}} = ReqLLM.model(model)

      body =
        openai_sse([
          %{choices: [text_choice("ok", "stop")]},
          %{
            choices: [],
            usage: %{prompt_tokens: 2_000, completion_tokens: 10, total_tokens: 2_010}
          }
        ])

      provider = openai(owner, 200, body)

      assert :ok = Provider.run(provider, openai_request(model: model), &send(owner, &1))
      assert_receive {:usage, usage}

      assert usage["input_tokens"] == 2_000
      assert usage["pricing"]["status"] == "list_rates"

      assert_in_delta usage["cost_usd"],
                      (2_000 * input_rate + 10 * output_rate) / 1_000_000,
                      1.0e-10
    end

    test "is on by default: the tools, the system prompt and the last message carry a breakpoint" do
      owner = self()
      provider = anthropic(owner, 200, sse(complete_answer("Short answer.")))

      assert :ok = Provider.run(provider, claude_request(tools: [FixtureTool]), &send(owner, &1))
      assert_receive {:wire, body}

      assert [%{"cache_control" => %{"type" => "ephemeral"}}] = body["system"]
      assert %{"cache_control" => %{"type" => "ephemeral"}} = List.last(body["tools"])

      assert %{"content" => content} = List.last(body["messages"])
      assert %{"cache_control" => %{"type" => "ephemeral"}} = List.last(content)
      assert_receive {:done, :stop}
    end

    test "an explicit anthropic_prompt_cache: false turns it off" do
      owner = self()

      provider =
        anthropic(owner, 200, sse(complete_answer("Short answer.")),
          anthropic_prompt_cache: false
        )

      assert :ok = Provider.run(provider, claude_request(), &send(owner, &1))
      assert_receive {:wire, body}

      refute JSON.encode!(body) =~ "cache_control"
    end

    test "cache reads and writes reach the usage contract" do
      owner = self()

      start =
        put_in(message_start()["message"]["usage"], %{
          "input_tokens" => 12,
          "cache_read_input_tokens" => 500,
          "cache_creation_input_tokens" => 100,
          "output_tokens" => 1
        })

      [_start | rest] = complete_answer("Cached.")
      provider = anthropic(owner, 200, sse([start | rest]))

      assert :ok = Provider.run(provider, claude_request(), &send(owner, &1))
      assert_receive {:usage, usage}

      normalized = Lemieux.Usage.normalize(usage, "anthropic:claude-haiku-4-5")
      assert normalized["cache_read_tokens"] == 500
      assert normalized["cache_write_tokens"] == 100
    end

    test "a request params opt-out wins over the default" do
      owner = self()
      provider = anthropic(owner, 200, sse(complete_answer("Short answer.")))

      request = claude_request(params: [anthropic_prompt_cache: false])

      assert :ok = Provider.run(provider, request, &send(owner, &1))
      assert_receive {:wire, body}
      refute JSON.encode!(body) =~ "cache_control"
    end

    test "is never asked of a provider that would reject the option" do
      owner = self()
      provider = openai(owner, 200, openai_sse([%{choices: [text_choice("ok", "stop")]}]))

      assert :ok = Provider.run(provider, openai_request(), &send(owner, &1))
      assert_receive {:wire, body}
      refute JSON.encode!(body) =~ "cache_control"
      assert_receive {:done, :stop}
    end
  end

  describe "a stream that broke off" do
    test "Anthropic's error event mid-answer is an interrupted, retryable failure" do
      # Anthropic sends `event: error` and closes the stream; ReqLLM's decoder
      # skips the event, so without this check the fragment below would have
      # been recorded as a complete answer.
      owner = self()

      events = [
        message_start(),
        text_block_start(),
        text_delta("Half an ans"),
        %{
          "type" => "error",
          "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
        }
      ]

      provider = anthropic(owner, 200, sse(events))

      assert {:error, %Interrupted{provider: "anthropic"} = reason} =
               Provider.run(provider, claude_request(), &send(owner, &1))

      assert ProviderError.category(reason) == :server
      assert ProviderError.transient?(reason)

      assert_receive {:text_delta, "Half an ans"}
      # What arrived is kept, marked, for the transcript and for a retry to skip.
      assert_receive {:message, %{"partial" => true, "content" => [%{"text" => "Half an ans"}]}}
      refute_receive {:done, _stop}
    end

    test "a complete Anthropic answer is not mistaken for one" do
      owner = self()
      provider = anthropic(owner, 200, sse(complete_answer("All of it.")))

      assert :ok = Provider.run(provider, claude_request(), &send(owner, &1))
      assert_receive {:message, message}
      refute Map.has_key?(message, "partial")
      assert_receive {:done, :stop}
    end

    test "an OpenAI-compatible error event inside a 200 keeps the provider's sentence" do
      owner = self()

      body =
        openai_sse(
          [%{choices: [%{index: 0, delta: %{content: "partial answer"}}]}],
          ~s({"error":{"message":"upstream overloaded"}})
        )

      provider = openai(owner, 200, body)

      assert {:error, %Interrupted{detail: "upstream overloaded", finish_reason: :error} = reason} =
               Provider.run(provider, openai_request(), &send(owner, &1))

      assert ProviderError.message(reason) =~ "upstream overloaded"
      assert ProviderError.transient?(reason)

      # ReqLLM assembles no message for this one; the deltas are what arrived.
      assert_receive {:text_delta, "partial answer"}
      refute_receive {:done, _stop}
    end

    test "a stream without a terminal marker is only suspect on Claude's wire" do
      # OpenAI-compatible servers are not all as careful about `[DONE]`; a
      # finish reason there is enough, and its absence is not treated as a cut.
      owner = self()
      body = openai_sse([%{choices: [%{index: 0, delta: %{content: "fine"}}]}], nil)
      provider = openai(owner, 200, body)

      assert :ok = Provider.run(provider, openai_request(), &send(owner, &1))
      assert_receive {:done, _stop}
    end
  end

  describe "an overflow refusal" do
    @prompt_too_long ~s({"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 213462 tokens > 200000 maximum"}})

    test "from Anthropic is a context limit, with the window it stated" do
      owner = self()
      provider = anthropic(owner, 400, @prompt_too_long)

      assert {:error, reason} = Provider.run(provider, claude_request(), &send(owner, &1))

      assert ProviderError.context_limit?(reason)
      assert ProviderError.stated_context_window(reason) == 200_000
      assert ProviderError.message(reason) =~ "prompt is too long"
      # The metadata event still sees the provider's own status.
      assert_receive {:response_metadata, %{status: 400}}
    end

    test "is not read from a provider that does not say it that way" do
      owner = self()
      provider = openai(owner, 400, @prompt_too_long)

      assert {:error, reason} = Provider.run(provider, openai_request(), &send(owner, &1))
      refute ProviderError.context_limit?(reason)
    end
  end

  describe "tool call arguments" do
    test "an optional property left null or empty is dropped; required and undeclared ones stay" do
      owner = self()

      arguments =
        JSON.encode!(%{
          "command" => "ls",
          "task_id" => nil,
          "note" => "",
          "label" => "",
          "extra" => nil
        })

      body =
        openai_sse([
          %{
            choices: [
              %{
                index: 0,
                delta: %{
                  tool_calls: [
                    %{
                      index: 0,
                      id: "call-1",
                      type: "function",
                      function: %{name: "fixture_tool", arguments: arguments}
                    }
                  ]
                }
              }
            ]
          },
          %{choices: [%{index: 0, delta: %{}, finish_reason: "tool_calls"}]}
        ])

      provider = openai(owner, 200, body)
      request = openai_request(tools: [FixtureTool])

      assert :ok = Provider.run(provider, request, &send(owner, &1))

      assert_receive {:tool_call, %{name: "fixture_tool", arguments: args}}
      assert args == %{"command" => "ls", "label" => "", "extra" => nil}
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp claude_request(opts \\ []) do
    Request.new(
      "anthropic:claude-haiku-4-5",
      Keyword.merge(
        [system: "Be brief.", entries: [Entry.new(:user, %{"text" => "Say something."})]],
        opts
      )
    )
  end

  defp openai_request(opts \\ []) do
    {model, opts} = Keyword.pop(opts, :model, "openai:gpt-5")

    Request.new(
      model,
      Keyword.merge([entries: [Entry.new(:user, %{"text" => "Say something."})]], opts)
    )
  end

  defp anthropic(owner, status, body, overrides \\ []) do
    url = serve(owner, status, body)

    Adapter.new(
      Keyword.merge(
        [api_key: "fixture-key", api_key_provider: :anthropic, base_url: url, max_retries: 0],
        overrides
      )
    )
  end

  defp openai(owner, status, body) do
    url = serve(owner, status, body)

    Adapter.new(
      api_key: "fixture-key",
      api_key_provider: :openai,
      max_retries: 0,
      transport_routes: %{
        "openai" => [provider: "openai", base_url: url, wire_protocol: "openai_chat"]
      }
    )
  end

  defp serve(owner, status, body) do
    {url, listener, server} =
      HTTPFixture.server(fn _path, _headers, request_body, socket ->
        send(owner, {:wire, JSON.decode!(request_body)})

        content_type = if status == 200, do: "text/event-stream", else: "application/json"

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} OK\r\n",
            "content-type: #{content_type}\r\n",
            "content-length: #{byte_size(body)}\r\n",
            "connection: close\r\n\r\n",
            body
          ])

        :sent
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    url
  end

  defp sse(events) do
    Enum.map_join(events, "", fn event ->
      "event: #{event["type"]}\ndata: #{JSON.encode!(event)}\n\n"
    end)
  end

  defp complete_answer(text) do
    [
      message_start(),
      text_block_start(),
      text_delta(text),
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 4}
      },
      %{"type" => "message_stop"}
    ]
  end

  defp message_start do
    %{
      "type" => "message_start",
      "message" => %{
        "id" => "msg_fixture",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-haiku-4-5",
        "content" => [],
        "stop_reason" => nil,
        "usage" => %{"input_tokens" => 12, "output_tokens" => 1}
      }
    }
  end

  defp text_block_start do
    %{
      "type" => "content_block_start",
      "index" => 0,
      "content_block" => %{"type" => "text", "text" => ""}
    }
  end

  defp text_delta(text) do
    %{
      "type" => "content_block_delta",
      "index" => 0,
      "delta" => %{"type" => "text_delta", "text" => text}
    }
  end

  defp text_choice(text, finish), do: %{index: 0, delta: %{content: text}, finish_reason: finish}

  # `tail` is what ends the stream: `[DONE]` by default, a raw event (an error)
  # instead, or nothing at all.
  defp openai_sse(chunks, tail \\ "[DONE]") do
    body = Enum.map_join(chunks, "", &("data: " <> JSON.encode!(&1) <> "\n\n"))
    if tail, do: body <> "data: " <> tail <> "\n\n", else: body
  end
end
