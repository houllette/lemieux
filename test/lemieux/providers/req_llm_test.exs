defmodule Lemieux.Providers.ReqLLMTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.Entry
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.Provider
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Tool.Attachment
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.Defaults

  defp request(entries, opts \\ []) do
    Request.new("anthropic:claude-haiku-4-5", Keyword.put(opts, :entries, entries))
  end

  describe "decode_arguments/1" do
    test "keeps a valid object" do
      assert ReqLLMProvider.decode_arguments(~s({"path":"README.md"})) ==
               {:ok, %{"path" => "README.md"}}
    end

    test "preserves why malformed JSON was invalid" do
      assert {:error, reason} = ReqLLMProvider.decode_arguments(~s({"path":))
      refute is_nil(reason)
    end

    test "rejects valid JSON that is not an object" do
      assert ReqLLMProvider.decode_arguments(~s(["README.md"])) ==
               {:error, {:expected_object, ["README.md"]}}
    end
  end

  describe "context/1" do
    test "a user entry becomes a user message" do
      context = ReqLLMProvider.context(request([Entry.new(:user, %{"text" => "hello"})]))

      assert [%Message{role: :user, content: [%ContentPart{type: :text, text: "hello"}]}] =
               Context.to_list(context)
    end

    test "an attached file rides on the same user message as its own content part" do
      entry =
        Entry.new(:user, %{
          "text" => "explain @a.ex",
          "attachments" => [%{"kind" => "file", "path" => "a.ex", "text" => "1\thello"}]
        })

      assert [%Message{role: :user, content: parts}] =
               Context.to_list(ReqLLMProvider.context(request([entry])))

      assert [
               %ContentPart{type: :text, text: "explain @a.ex"},
               %ContentPart{type: :text, text: "1\thello"}
             ] = parts
    end

    test "an attached image is decoded back to bytes for the provider to encode" do
      png = <<0x89, "PNG", 0, 1, 2>>

      entry =
        Entry.new(:user, %{
          "text" => "what is this",
          "attachments" => [
            %{
              "kind" => "image",
              "path" => "shot.png",
              "media_type" => "image/png",
              "data" => Base.encode64(png)
            }
          ]
        })

      assert [%Message{role: :user, content: [_text, image]}] =
               Context.to_list(ReqLLMProvider.context(request([entry])))

      # Raw, not base64: every provider encoder base64s `:data` itself, so
      # passing it encoded would send a base64 of a base64.
      assert %ContentPart{type: :image, data: ^png, media_type: "image/png"} = image
    end

    test "an attached document keeps its filename, which is what a provider labels it with" do
      entry =
        Entry.new(:user, %{
          "text" => "read it",
          "attachments" => [
            %{
              "kind" => "document",
              "path" => "docs/paper.pdf",
              "media_type" => "application/pdf",
              "data" => Base.encode64("%PDF-1.7")
            }
          ]
        })

      assert [%Message{role: :user, content: [_text, file]}] =
               Context.to_list(ReqLLMProvider.context(request([entry])))

      assert %ContentPart{type: :file, filename: "paper.pdf", media_type: "application/pdf"} =
               file
    end

    test "a blob that will not decode is dropped rather than sent as a hole" do
      entry =
        Entry.new(:user, %{
          "text" => "look",
          "attachments" => [
            %{"kind" => "image", "path" => "x.png", "media_type" => "image/png", "data" => "!!!!"}
          ]
        })

      assert [%Message{role: :user, content: [%ContentPart{type: :text, text: "look"}]}] =
               Context.to_list(ReqLLMProvider.context(request([entry])))
    end

    test "an empty attachment list is the message it was before attachments existed" do
      entry = Entry.new(:user, %{"text" => "hello", "attachments" => []})

      assert [%Message{role: :user, content: [%ContentPart{type: :text, text: "hello"}]}] =
               Context.to_list(ReqLLMProvider.context(request([entry])))
    end

    test "an attachment shape this build does not know is dropped, not sent as nothing" do
      # Payloads may gain fields within a schema version, so a newer lemieux
      # can have written a kind this one has no content part for. Assembling a
      # message with a hole in it is a provider error on a turn whose text was
      # fine.
      entry =
        Entry.new(:user, %{
          "text" => "look",
          "attachments" => [%{"kind" => "hologram", "path" => "a.ex"}]
        })

      assert [%Message{role: :user, content: [%ContentPart{type: :text, text: "look"}]}] =
               Context.to_list(ReqLLMProvider.context(request([entry])))
    end

    test "the system prompt leads the conversation" do
      context =
        ReqLLMProvider.context(request([Entry.new(:user, %{"text" => "hi"})], system: "be terse"))

      assert [%Message{role: :system}, %Message{role: :user}] = Context.to_list(context)
    end

    test "no system prompt means no system message, rather than an empty one" do
      context = ReqLLMProvider.context(request([Entry.new(:user, %{"text" => "hi"})]))

      assert [%Message{role: :user}] = Context.to_list(context)
    end

    test "an assistant entry's content parts come back as content parts" do
      entry =
        Entry.new(:assistant, %{
          "content" => [
            %{"type" => "thinking", "text" => "let me see"},
            %{"type" => "text", "text" => "hello"}
          ]
        })

      # A thinking model on OpenAI's wire takes thinking back as reasoning
      # content; Claude is the exception, below.
      request = Request.new("openai:gpt-5", entries: [entry])

      assert [%Message{role: :assistant, content: content}] =
               Context.to_list(ReqLLMProvider.context(request))

      assert [
               %ContentPart{type: :thinking, text: "let me see"},
               %ContentPart{type: :text, text: "hello"}
             ] = content
    end

    test "reasoning details survive the transcript" do
      # The signature is what lets a thinking model continue a conversation it
      # started. Dropped here, the next request is rejected outright by the
      # provider — so this is the one field in an assistant entry that has to
      # come back exactly as it went in.
      entry =
        Entry.new(:assistant, %{
          "content" => [%{"type" => "text", "text" => "hi"}],
          "reasoning_details" => [
            %{
              "text" => "thought",
              "signature" => "sig-abc",
              "encrypted?" => true,
              "provider" => "anthropic",
              "format" => "anthropic-thinking-v1",
              "index" => 0,
              "provider_data" => %{"type" => "thinking"}
            }
          ]
        })

      assert [%Message{reasoning_details: [detail]}] =
               Context.to_list(ReqLLMProvider.context(request([entry])))

      assert detail.signature == "sig-abc"
      assert detail.encrypted? == true
      assert detail.provider == :anthropic
      assert detail.index == 0
      assert detail.provider_data == %{"type" => "thinking"}
    end

    test "an entry that is not part of the conversation sends no message" do
      entries = [
        Entry.new(:user, %{"text" => "hi"}),
        Entry.new(:error, %{"reason" => ":closed"}),
        Entry.new(:cancelled, %{}),
        # Where a transcript came from, and what the session was configured
        # with, are lemieux's business and not the model's.
        Entry.new(:fork, %{"from" => "other", "at" => "01ABC"}),
        Entry.new(:session, %{"model" => "m", "system" => "s", "tools" => [], "cwd" => "/"})
      ]

      assert [%Message{role: :user}] = Context.to_list(ReqLLMProvider.context(request(entries)))
    end

    test "a failed tool result keeps its provider-visible error status" do
      entry =
        Entry.new(:tool_result, %{
          "call_id" => "call-1",
          "name" => "read",
          "output" => "",
          "error" => true
        })

      assert [
               %Message{
                 role: :tool,
                 metadata: %{is_error: true},
                 content: [%ContentPart{text: output}]
               }
             ] =
               Context.to_list(ReqLLMProvider.context(request([entry])))

      assert output =~ "failed"
    end

    test "a successful tool result is not marked as an error" do
      entry =
        Entry.new(:tool_result, %{
          "call_id" => "call-1",
          "name" => "read",
          "output" => "contents",
          "error" => false
        })

      assert [%Message{role: :tool, metadata: metadata}] =
               Context.to_list(ReqLLMProvider.context(request([entry])))

      refute metadata[:is_error]
    end

    test "failed tool results do not send Anthropic metadata through an OpenAI wire format" do
      entry =
        Entry.new(:tool_result, %{
          "call_id" => "call-denied",
          "name" => "bash",
          "output" => "denied: command is outside the allowed policy",
          "error" => true
        })

      for model <- ["openai:gpt-4o-mini", "zai_coding_plan:glm-5.3"] do
        context = ReqLLMProvider.context(Request.new(model, entries: [entry]))

        %{messages: [message]} =
          Defaults.encode_context_to_openai_format(context, model)

        refute Map.has_key?(message, :metadata)
        assert message.tool_call_id == "call-denied"
        assert message.content =~ "denied:"
      end
    end

    test "tool error metadata follows the transport while reasoning follows the logical model" do
      assistant =
        Entry.new(:assistant, %{
          "content" => [%{"type" => "thinking", "text" => "Inspect the file"}],
          "tool_calls" => [
            %{"id" => "call-1", "name" => "read", "arguments" => %{"path" => "missing"}}
          ]
        })

      result =
        Entry.new(:tool_result, %{
          "call_id" => "call-1",
          "name" => "read",
          "output" => "",
          "error" => true
        })

      request = request([assistant, result])

      assert [%Message{content: [%ContentPart{type: :thinking}]}, tool] =
               Context.to_list(ReqLLMProvider.context(request, "openai:claude-haiku-4-5"))

      assert tool.metadata == %{}
      assert [%ContentPart{text: "[tool failed without an error message]"}] = tool.content

      for target <- [
            "anthropic:claude-haiku-4-5",
            "amazon_bedrock:anthropic.claude-haiku-4-5",
            "google_vertex:claude-haiku-4-5"
          ] do
        assert [_, %Message{metadata: %{is_error: true}}] =
                 Context.to_list(ReqLLMProvider.context(request, target))
      end
    end
  end

  describe "a transcript replayed to a model that cannot think" do
    # The real scenario: `lmx --resume ID --model openai:gpt-4o-mini` on a
    # conversation recorded against Claude. The thinking is in the transcript
    # because it happened; sending it to a model with no such concept is a
    # request that model has no way to accept.
    setup do
      thinking =
        Entry.new(:assistant, %{
          "content" => [
            %{"type" => "thinking", "text" => "let me see"},
            %{"type" => "text", "text" => "hello"}
          ],
          "reasoning_details" => [
            %{"text" => "thought", "signature" => "sig-abc", "provider" => "anthropic"}
          ]
        })

      %{entry: thinking}
    end

    test "keeps the thinking for a model that thinks", %{entry: entry} do
      request = Request.new("anthropic:claude-sonnet-5", entries: [entry])

      assert [%Message{content: content, reasoning_details: [_detail]}] =
               Context.to_list(ReqLLMProvider.context(request))

      assert [%ContentPart{type: :thinking}, %ContentPart{type: :text}] = content
    end

    test "drops it for a model that does not", %{entry: entry} do
      request = Request.new("openai:gpt-4o-mini", entries: [entry])

      assert [%Message{content: content} = message] =
               Context.to_list(ReqLLMProvider.context(request))

      assert [%ContentPart{type: :text, text: "hello"}] = content
      assert message.reasoning_details == nil
    end

    test "an assistant turn that was only thinking still says something", %{entry: _entry} do
      # Dropping the thinking would otherwise leave an assistant message with
      # no content at all, which providers reject as readily as they reject
      # thinking they do not understand.
      entry =
        Entry.new(:assistant, %{"content" => [%{"type" => "thinking", "text" => "hmm"}]})

      request = Request.new("openai:gpt-4o-mini", entries: [entry])

      assert Context.to_list(ReqLLMProvider.context(request)) == []
    end

    test "a model nobody has heard of is given the transcript as recorded", %{entry: entry} do
      # No capability data means no grounds to remove anything. Sending too
      # much is a clear error from the provider; sending too little is a
      # conversation the model answers confidently and wrong.
      request = Request.new("nonsense:model", entries: [entry])

      assert [%Message{content: [%ContentPart{type: :thinking} | _rest]}] =
               Context.to_list(ReqLLMProvider.context(request))
    end
  end

  describe "thinking replayed to Claude" do
    # Anthropic refuses a thinking block without its signature, and every
    # later request of the session with it. Signed thinking travels in the
    # reasoning details; thinking *content* — cut off mid-thought, or written by
    # another provider before a model switch — has no signature to send.
    setup do
      unsigned =
        Entry.new(:assistant, %{
          "content" => [
            %{"type" => "thinking", "text" => "half a thought"},
            %{"type" => "text", "text" => "hello"}
          ]
        })

      %{unsigned: unsigned, question: Entry.new(:user, %{"text" => "go on"})}
    end

    test "unsigned thinking is not sent to a Claude wire", %{unsigned: entry, question: question} do
      for target <- [
            "anthropic:claude-haiku-4-5",
            "amazon_bedrock:anthropic.claude-haiku-4-5",
            "google_vertex:claude-haiku-4-5"
          ] do
        request = Request.new("anthropic:claude-haiku-4-5", entries: [entry, question])

        assert [%Message{role: :assistant, content: [%ContentPart{type: :text}]}, _question] =
                 Context.to_list(ReqLLMProvider.context(request, target)),
               target
      end
    end

    test "other thinking models still receive it as their own reasoning", %{
      unsigned: entry,
      question: question
    } do
      request = Request.new("openai:gpt-5", entries: [entry, question])

      assert [%Message{content: [%ContentPart{type: :thinking}, %ContentPart{type: :text}]}, _] =
               Context.to_list(ReqLLMProvider.context(request))
    end

    test "details another provider signed do not count as Claude's", %{question: question} do
      entry =
        Entry.new(:assistant, %{
          "content" => [
            %{"type" => "thinking", "text" => "glm thought"},
            %{"type" => "text", "text" => "hello"}
          ],
          "tool_calls" => [%{"id" => "call-1", "name" => "read", "arguments" => %{}}],
          "reasoning_details" => [%{"text" => "glm thought", "provider" => "zai"}]
        })

      request = Request.new("anthropic:claude-haiku-4-5", entries: [entry, question])

      assert [%Message{content: [%ContentPart{type: :text}], tool_calls: [_call]}, _] =
               Context.to_list(ReqLLMProvider.context(request))
    end

    test "Anthropic's encoder is given no thinking block without a signature", %{
      unsigned: entry,
      question: question
    } do
      request = Request.new("anthropic:claude-haiku-4-5", entries: [entry, question])
      {:ok, model} = ReqLLM.model("anthropic:claude-haiku-4-5")

      %{messages: [assistant, _user]} =
        ReqLLM.Providers.Anthropic.Context.encode_request(ReqLLMProvider.context(request), model)

      refute inspect(assistant) =~ "thinking"
    end

    test "a turn that was only thinking is not sent at all" do
      entry = Entry.new(:assistant, %{"content" => [%{"type" => "thinking", "text" => "hmm"}]})

      for model <- ["openai:gpt-5", "anthropic:claude-haiku-4-5"] do
        request =
          Request.new(model, entries: [entry, Entry.new(:user, %{"text" => "and?"})])

        assert [%Message{role: :user}] = Context.to_list(ReqLLMProvider.context(request)), model
      end
    end
  end

  describe "an abandoned attempt" do
    # A request that dies mid-answer leaves what arrived and a provider error.
    # Sent again, that fragment is the request's last word: a prefill Claude
    # continues instead of answering (and refuses under extended thinking), a
    # final assistant message Mistral rejects outright.
    setup do
      %{
        question: Entry.new(:user, %{"text" => "fix the tests"}),
        fragment:
          Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "I'll start by "}]}),
        failure: Entry.new(:error, %{"reason" => "the provider stopped", "category" => "server"}),
        answer: Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "Done."}]})
      }
    end

    defp roles(entries) do
      Request.new("openai:gpt-5", entries: entries)
      |> ReqLLMProvider.context()
      |> Context.to_list()
      |> Enum.map(& &1.role)
    end

    test "is not replayed when a retry resends the conversation", c do
      assert roles([c.question, c.fragment, c.failure]) == [:user]
    end

    test "is not replayed beside the answer that replaced it", c do
      assert roles([c.question, c.fragment, c.failure, c.answer]) == [:user, :assistant]

      assert [_, %Message{content: [%ContentPart{text: "Done."}]}] =
               Request.new("openai:gpt-5", entries: [c.question, c.fragment, c.failure, c.answer])
               |> ReqLLMProvider.context()
               |> Context.to_list()
    end

    test "stays when the person has answered it since", c do
      reply = Entry.new(:user, %{"text" => "no, start with the parser"})

      assert roles([c.question, c.fragment, c.failure, reply]) == [:user, :assistant, :user]
    end

    test "is recognised by the adapter's partial mark without an error entry", c do
      partial =
        Entry.new(:assistant, %{
          "content" => [%{"type" => "text", "text" => "I'll start by "}],
          "partial" => true
        })

      assert roles([c.question, partial]) == [:user]
      assert roles([c.question, partial, c.answer]) == [:user, :assistant]
    end

    test "a finished answer, a turn with tool calls and a budget stop are not attempts", c do
      # A compaction summary is asked about a conversation that may end on an
      # ordinary answer; that answer is conversation.
      assert roles([c.question, c.answer]) == [:user, :assistant]

      calling =
        Entry.new(:assistant, %{
          "content" => [%{"type" => "text", "text" => "Reading."}],
          "tool_calls" => [%{"id" => "call-1", "name" => "read", "arguments" => %{}}]
        })

      assert roles([c.question, calling, c.failure]) == [:user, :assistant]

      budget = Entry.new(:error, %{"reason" => "stopped before the request"})
      assert roles([c.question, c.answer, budget]) == [:user, :assistant]
    end
  end

  describe "run/3 before the network" do
    test "an Anthropic-incompatible MCP tool is rejected locally by name" do
      for keyword <- ~w(anyOf oneOf allOf) do
        tool = incompatible_remote_tool(keyword)

        assert {:error,
                {:tool_schema_unsupported, "anthropic", "fixture__choose", ^keyword, message}} =
                 Provider.validate_model(
                   ReqLLMProvider.new(api_key: "test-key"),
                   "anthropic:claude-haiku-4-5",
                   [tool]
                 )

        assert message =~ "fixture__choose"
        assert message =~ "top-level #{keyword}"

        assert ProviderError.message({:tool_schema_unsupported, nil, nil, nil, message}) ==
                 message
      end
    end

    test "top-level schema combinators remain valid for providers that accept them" do
      tool = incompatible_remote_tool("anyOf")

      assert :ok =
               Provider.validate_model(
                 ReqLLMProvider.new(api_key: "test-key"),
                 "openai:gpt-4o-mini",
                 [tool]
               )
    end

    test "schema preflight follows an API-compatible transport route" do
      provider =
        ReqLLMProvider.new(
          api_key: "test-key",
          transport_routes: %{
            "openai" => [provider: "anthropic", base_url: "https://gateway.example.test"]
          }
        )

      assert {:error,
              {:tool_schema_unsupported, "anthropic", "fixture__choose", "anyOf", _message}} =
               Provider.validate_model(
                 provider,
                 "openai:gpt-4o-mini",
                 [incompatible_remote_tool("anyOf")]
               )
    end

    test "the CLI default resolves through ReqLLM, as does the Coding Plan row" do
      assert {:ok, model} = ReqLLM.model(Options.default_model())
      assert model.provider == :anthropic
      assert ReqLLM.Keys.env_var_name(model.provider) == "ANTHROPIC_API_KEY"

      assert {:ok, coding_plan} = ReqLLM.model("zai_coding_plan:glm-5.3")
      assert coding_plan.provider == :zai_coding_plan
      assert ReqLLM.Keys.env_var_name(coding_plan.provider) == "ZAI_API_KEY"
    end

    test "an API-compatible transport route keeps the logical credential" do
      routes = %{
        "zai_coding_plan" => [provider: "openai", base_url: "https://api.z.ai/api/coding/paas/v4"]
      }

      assert {:ok, {"openai:glm-5.1", options}} =
               ReqLLMProvider.request_target(
                 "zai_coding_plan:glm-5.1",
                 transport_routes: routes,
                 catalog_fallbacks: ["zai_coding_plan:glm-5.3"],
                 api_key: "coding-plan-key",
                 max_tokens: 128
               )

      assert options[:base_url] == "https://api.z.ai/api/coding/paas/v4"
      assert options[:api_key] == "coding-plan-key"
      assert options[:max_tokens] == 128
      refute Keyword.has_key?(options, :transport_routes)
      refute Keyword.has_key?(options, :catalog_fallbacks)
    end

    # Found live: `gpt-5.6` at medium effort spent longer than req_llm's
    # thirty-second default thinking before its first token, and the harness
    # reported a timeout the provider was never going to produce.
    test "a stream is given longer to go quiet than a web request would be" do
      {_module, state} = ReqLLMProvider.new()
      assert state.options[:receive_timeout] == :timer.minutes(2)

      {_module, explicit} = ReqLLMProvider.new(receive_timeout: 5_000)
      assert explicit.options[:receive_timeout] == 5_000
    end

    test "an API-compatible transport route does not leak into another provider" do
      routes = %{
        "zai_coding_plan" => [provider: "openai", base_url: "https://api.z.ai/api/coding/paas/v4"]
      }

      assert {:ok, {"anthropic:claude-haiku-4-5", options}} =
               ReqLLMProvider.request_target(
                 "anthropic:claude-haiku-4-5",
                 transport_routes: routes,
                 receive_timeout: :infinity
               )

      assert options == [receive_timeout: :infinity]
    end

    test "the Ollama Cloud route uses Ollama's credential on its OpenAI-compatible API" do
      routes = %{
        "ollama_cloud" => [
          provider: "openai",
          base_url: "https://ollama.com/v1",
          credential_provider: "ollama"
        ]
      }

      assert ReqLLM.Keys.env_var_name(:ollama) == "OLLAMA_API_KEY"

      assert {:ok, {"openai:gpt-oss:120b", options}} =
               ReqLLMProvider.request_target(
                 "ollama_cloud:gpt-oss:120b",
                 transport_routes: routes,
                 api_key: "cloud-key"
               )

      assert options[:base_url] == "https://ollama.com/v1"
      assert options[:api_key] == "cloud-key"
      refute Keyword.has_key?(options, :credential_provider)
    end

    test "a session's string reasoning effort reaches ReqLLM in its canonical type" do
      assert {:ok, {"zai:glm-5.2", options}} =
               ReqLLMProvider.request_target(
                 "zai:glm-5.2",
                 api_key: "zai-key",
                 reasoning_effort: "high"
               )

      assert options[:reasoning_effort] == :high

      model = ReqLLM.model!("zai:glm-5.2")
      context = Context.new("tell me a fun fact")

      assert processed =
               ReqLLM.Provider.Options.process_stream!(
                 ReqLLM.Providers.Zai,
                 :chat,
                 model,
                 context,
                 options
               )

      assert processed[:reasoning_effort] == :high
    end

    test "a model that cannot use tools is refused before the request is made" do
      request =
        Request.new("openai:gpt-4o-mini",
          entries: [Entry.new(:user, %{"text" => "hi"})],
          tools: [Lemieux.Tools.Read]
        )

      # Asserted against a model that *can* use tools, so this test is about
      # the check and not about which models the database happens to describe.
      assert {:ok, model} = ReqLLM.model("openai:gpt-4o-mini")
      assert ReqLLM.ModelHelpers.tools_enabled?(model)

      assert {:ok, _} = ReqLLM.model("openai:gpt-4o-mini")
      assert :ok == ReqLLMProvider.check_tools(model, request)
    end

    test "and the message names the model and what to do about it" do
      request = Request.new("m", tools: [Lemieux.Tools.Read])

      # Described, and described as having no tools — which is the only case
      # that may be refused. See "a model the database knows nothing about".
      model = %LLMDB.Model{
        id: "toolless",
        provider: :none,
        model: "toolless",
        capabilities: %{chat: true, tools: %{enabled: false}}
      }

      assert {:error, {:tools_unsupported, "toolless", message}} =
               ReqLLMProvider.check_tools(model, request)

      assert message =~ "tools"
    end

    test "a model with no tools asked of it is fine either way" do
      model = %LLMDB.Model{
        id: "toolless",
        provider: :none,
        model: "toolless",
        capabilities: %{chat: true, tools: %{enabled: false}}
      }

      assert :ok == ReqLLMProvider.check_tools(model, Request.new("m"))
    end

    test "an unresolvable model is named, not attempted" do
      provider = ReqLLMProvider.new()

      assert {:error, {:unknown_model, "nonsense", _hint}} =
               Provider.run(provider, Request.new("nonsense"), fn _event -> :ok end)
    end

    test "a missing API key is an error about the environment, not an HTTP failure" do
      # An empty key stands in for an absent one so the test does not depend
      # on what happens to be exported in the shell that runs it.
      provider = ReqLLMProvider.new(api_key: "")

      assert {:error, {:missing_api_key, :anthropic, hint}} =
               Provider.run(provider, request([]), fn _event -> :ok end)

      assert hint =~ "ANTHROPIC_API_KEY"
    end
  end

  describe "a provider that needs no key" do
    # Ollama runs on the machine and has nothing to authenticate to. Refusing
    # its requests for want of an API key is how a local model becomes
    # unreachable through a check that exists to be helpful.
    test "is not refused for want of one" do
      parent = self()

      {url, listener, server} =
        LemieuxTest.HTTPFixture.server(fn _headers, body, _socket ->
          send(parent, {:keyless_request, JSON.decode!(body)})

          %{
            status: 200,
            headers: [{"content-type", "text/event-stream"}],
            body:
              "data: " <>
                JSON.encode!(%{
                  choices: [%{index: 0, delta: %{content: "hello"}, finish_reason: "stop"}]
                }) <>
                "\n\ndata: [DONE]\n\n"
          }
        end)

      on_exit(fn ->
        Process.exit(server, :kill)
        :gen_tcp.close(listener)
      end)

      # No window lookup: this stub answers one request, and asking it what
      # window it serves is `Lemieux.Providers.ReqLLMLocalTest`'s business.
      provider =
        ReqLLMProvider.new(base_url: url, api_key: "", max_retries: 0, ollama_window: false)

      request =
        Request.new("ollama:gemma4:12b", entries: [Entry.new(:user, %{"text" => "hi"})])

      # A real response proves the keyless request crossed the adapter. The
      # developer's Ollama server (or connection retries when absent) must not
      # determine either the outcome or duration of this unit test.
      assert :ok = Provider.run(provider, request, &send(parent, {:keyless_event, &1}))
      assert_receive {:keyless_request, %{"model" => "gemma4:12b"}}
      assert_receive {:keyless_event, {:text_delta, "hello"}}
    end

    test "while one that does is still checked up front" do
      provider = ReqLLMProvider.new(api_key: "")

      assert {:error, {:missing_api_key, :anthropic, _hint}} =
               Provider.run(provider, request([]), fn _event -> :ok end)
    end
  end

  describe "a model the database knows nothing about" do
    # Every locally-served model is one of these: `limits` and `capabilities`
    # come back nil, because nobody published a datasheet for the quantisation
    # you pulled last night. Absent data is not evidence of an absent
    # capability, and reading it as one makes local models useless.
    setup do
      %{model: %LLMDB.Model{id: "local", provider: :ollama, model: "local", capabilities: nil}}
    end

    test "may still be given tools", %{model: model} do
      request = Request.new("ollama:local", tools: [Lemieux.Tools.Read])

      assert :ok == ReqLLMProvider.check_tools(model, request)
    end

    test "and is only refused when the database says it cannot", %{model: _model} do
      known = %LLMDB.Model{
        id: "toolless",
        provider: :none,
        model: "toolless",
        capabilities: %{chat: true, tools: %{enabled: false}}
      }

      assert {:error, {:tools_unsupported, _name, _message}} =
               ReqLLMProvider.check_tools(known, Request.new("m", tools: [Lemieux.Tools.Read]))
    end

    test "keeps the thinking in a transcript replayed to it" do
      entry =
        Entry.new(:assistant, %{
          "content" => [
            %{"type" => "thinking", "text" => "let me see"},
            %{"type" => "text", "text" => "hello"}
          ]
        })

      request = Request.new("ollama:qwen3.8:27b-mxfp8", entries: [entry])

      assert [%Message{content: [%ContentPart{type: :thinking} | _rest]}] =
               Context.to_list(ReqLLMProvider.context(request))
    end
  end

  describe "a request that produced nothing" do
    # Found live: OpenAI with no credit on the account answers the streaming
    # path with {:ok, response}, an empty stream and finish_reason :incomplete.
    # Reported as a finish, that is a blank answer and a person with no idea
    # why.
    defp result(fields) do
      Map.merge(%{message: %Message{role: :assistant, content: []}, finish_reason: :stop}, fields)
    end

    test "is an error when it also ended abnormally" do
      assert {:error, reason} =
               ReqLLMProvider.check_answered(
                 result(%{finish_reason: :incomplete}),
                 "openai:gpt-4o-mini"
               )

      assert {:unanswered, "openai:gpt-4o-mini", :incomplete} = reason
      assert ProviderError.message(reason) =~ "answered nothing"
      assert ProviderError.message(reason) =~ "credit"

      # Indistinguishable, from the response, from a stream cut before the
      # first token — so it is the provider failing, and the session asks
      # again. A refusal that repeats fails the retries with this sentence.
      assert ProviderError.category(reason) == :server
      assert ProviderError.transient?(reason)
    end

    test "is allowed when the model simply stopped" do
      assert :ok == ReqLLMProvider.check_answered(result(%{finish_reason: :stop}), "m")
    end

    test "a truncated answer keeps its content rather than becoming an error" do
      message = %Message{role: :assistant, content: [ContentPart.text("half a sen")]}

      assert :ok ==
               ReqLLMProvider.check_answered(
                 result(%{message: message, finish_reason: :length}),
                 "m"
               )
    end

    test "a turn that only called tools is an answer" do
      message = %Message{
        role: :assistant,
        content: [],
        tool_calls: [
          %ReqLLM.ToolCall{id: "1", type: :function, function: %{name: "read", arguments: %{}}}
        ]
      }

      assert :ok ==
               ReqLLMProvider.check_answered(
                 result(%{message: message, finish_reason: :tool_calls}),
                 "m"
               )
    end

    test "an object part remains public content on an abnormal stop" do
      message = %Message{role: :assistant, content: [%{type: :object, object: %{"answer" => 42}}]}

      assert :ok ==
               ReqLLMProvider.check_answered(
                 result(%{message: message, finish_reason: :length}),
                 "m"
               )
    end
  end

  describe "images and documents a tool returned" do
    @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 4::32, 4::32, 8, 6, 0, 0, 0>>

    defp call(id, name \\ "browser") do
      Entry.new(:assistant, %{
        "content" => [],
        "tool_calls" => [%{"id" => id, "name" => name, "arguments" => %{}}]
      })
    end

    defp shot(id, name \\ "browser") do
      Entry.new(:tool_result, %{
        "call_id" => id,
        "name" => name,
        "output" => "[image: image/png]",
        "attachments" => [Attachment.new(:image, "image/png", @png, path: id)]
      })
    end

    # Claude looks for what a call returned inside the call's result.
    test "ride inside the tool result for Claude" do
      context =
        ReqLLMProvider.context(request([call("t1"), shot("t1")]), "anthropic:claude-sonnet-5")

      assert [%Message{role: :assistant}, %Message{role: :tool, content: [text, image]}] =
               Context.to_list(context)

      assert %ContentPart{type: :text, text: "[image: image/png]"} = text
      assert %ContentPart{type: :image, data: @png, media_type: "image/png"} = image
    end

    # A chat wire refuses an image in a tool message, and nothing may come
    # between the results of one assistant turn's calls.
    test "follow the whole run of tool results in one user message on a chat wire" do
      entries = [
        Entry.new(:assistant, %{
          "content" => [],
          "tool_calls" => [
            %{"id" => "t1", "name" => "browser", "arguments" => %{}},
            %{"id" => "t2", "name" => "browser", "arguments" => %{}}
          ]
        }),
        shot("t1"),
        shot("t2"),
        Entry.new(:user, %{"text" => "which one is right?"})
      ]

      assert [
               %Message{role: :assistant},
               %Message{role: :tool, tool_call_id: "t1", content: [%ContentPart{type: :text}]},
               %Message{role: :tool, tool_call_id: "t2", content: [%ContentPart{type: :text}]},
               %Message{role: :user, content: follow_up},
               %Message{role: :user, content: [%ContentPart{text: "which one is right?"}]}
             ] = Context.to_list(ReqLLMProvider.context(request(entries), "openai:gpt-5"))

      assert [
               %ContentPart{type: :text, text: "[attached by the browser call above (t1)]"},
               %ContentPart{type: :image, data: @png},
               %ContentPart{type: :text, text: "[attached by the browser call above (t2)]"},
               %ContentPart{type: :image, data: @png}
             ] = follow_up
    end

    # After `/model` to a text-only model, the old image would be a refusal of
    # every request that still carried it.
    test "are described to a model known not to view images, wherever they came from" do
      user =
        Entry.new(:user, %{
          "text" => "look",
          "attachments" => [
            Attachment.new(:image, "image/png", @png, path: "me.png")
          ]
        })

      messages =
        [user, call("t1"), shot("t1")]
        |> request()
        |> ReqLLMProvider.context("zai_coding_plan:glm-5.3")
        |> Context.to_list()

      assert [
               %Message{role: :user, content: [_look, %ContentPart{type: :text, text: note}]},
               %Message{role: :assistant},
               %Message{role: :tool, content: [%ContentPart{type: :text, text: output}]}
             ] = messages

      assert note == "[the image me.png is not shown: the current model cannot view images]"
      assert output =~ "[image: image/png]\n[the image t1 is not shown"
    end

    test "input_modalities/2 reads the model catalog, and unknown is its own answer" do
      {module, state} = ReqLLMProvider.new()

      assert :image in module.input_modalities(state, "anthropic:claude-sonnet-5")
      refute :image in module.input_modalities(state, "zai_coding_plan:glm-5.3")
      assert module.input_modalities(state, "nonsense:model") == :unknown
    end
  end

  describe "context_window/2" do
    test "is read from the model database rather than a table lemieux keeps" do
      window = Provider.context_window(ReqLLMProvider.new(), "anthropic:claude-sonnet-5")

      # Asserted as a range rather than a number: this comes from req_llm's
      # database, and pinning the exact figure would make a dependency bump
      # fail a test about lemieux.
      assert is_integer(window)
      assert window >= 100_000
    end

    test "a model nobody has heard of is nil, not a guess" do
      assert Provider.context_window(ReqLLMProvider.new(), "nonsense:model") == nil
    end

    test "planning falls back to a stated guess only when the provider knows nothing" do
      provider = ReqLLMProvider.new()
      window = Provider.context_window(provider, "anthropic:claude-haiku-4-5")

      assert Provider.planning_window(provider, "anthropic:claude-haiku-4-5") ==
               {window, :provider}

      assert Provider.planning_window(provider, "nonsense:model") ==
               {Provider.fallback_context_window(), :fallback}

      # A double with no catalog is the same unknown.
      assert {_window, :fallback} =
               Provider.planning_window(Scripted.new([]), "anthropic:claude-haiku-4-5")
    end

    test "a provider that does not implement it answers nil rather than failing" do
      assert Provider.context_window(Scripted.new([]), "anything") == nil
    end
  end

  describe "model discovery and validation" do
    test "lists canonical models for a configured provider" do
      models =
        Provider.available_models(ReqLLMProvider.new(api_key: "test-key"),
          scope: :anthropic,
          require: [chat: true]
        )

      assert models != []
      assert Enum.all?(models, &String.starts_with?(&1, "anthropic:"))
    end

    test "a provider-scoped key map advertises only providers with keys" do
      anthropic = ReqLLMProvider.new(api_keys: %{anthropic: "anthropic-key"})

      assert models = Provider.available_models(anthropic, require: [chat: true, tools: true])
      assert models != []
      assert Enum.all?(models, &String.starts_with?(&1, "anthropic:"))

      both =
        ReqLLMProvider.new(api_keys: %{"openai" => "openai-key", anthropic: "anthropic-key"})

      both_models = Provider.available_models(both, require: [chat: true, tools: true])
      assert Enum.any?(both_models, &String.starts_with?(&1, "anthropic:"))
      assert Enum.any?(both_models, &String.starts_with?(&1, "openai:"))
      assert length(both_models) > length(models)
    end

    test "an explicit empty key map advertises no ambient providers" do
      assert Provider.available_models(
               ReqLLMProvider.new(api_keys: %{}),
               require: [chat: true, tools: true]
             ) == []
    end

    test "a legacy scalar key cannot widen an unscoped catalog" do
      provider = ReqLLMProvider.new(api_key: "one-provider-key")

      assert Provider.available_models(provider, require: [chat: true, tools: true]) == []

      assert Provider.available_models(provider,
               scope: :anthropic,
               require: [chat: true, tools: true]
             ) != []
    end

    test "legacy callback wrappers may keep scope in provider state" do
      models =
        ReqLLMProvider.available_models(
          [api_key: "one-provider-key", scope: :anthropic],
          require: [chat: true, tools: true]
        )

      assert models != []
      assert Enum.all?(models, &String.starts_with?(&1, "anthropic:"))
    end

    test "provider-scoped credentials reject a model belonging to another provider" do
      assert {:error, {:missing_api_key, :openai, hint}} =
               Provider.validate_model(
                 ReqLLMProvider.new(api_keys: %{anthropic: "anthropic-key"}),
                 "openai:gpt-4o-mini",
                 []
               )

      assert hint =~ ":api_keys"

      assert {:error, {:missing_api_key, :openai, scalar_hint}} =
               Provider.validate_model(
                 ReqLLMProvider.new(
                   api_key: "anthropic-key",
                   api_key_provider: :anthropic
                 ),
                 "openai:gpt-4o-mini",
                 []
               )

      assert scalar_hint =~ "anthropic"
    end

    test "provider state inspection never includes credentials or gateway options" do
      provider =
        ReqLLMProvider.new(
          api_keys: %{anthropic: "do-not-print-this"},
          base_url: "https://credential.example.test"
        )

      inspected = inspect(provider)
      refute inspected =~ "do-not-print-this"
      refute inspected =~ "credential.example.test"
    end

    test "scalar and mapped keys cannot be combined ambiguously" do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        ReqLLMProvider.new(api_key: "one", api_keys: %{anthropic: "two"})
      end

      assert_raise ArgumentError, ~r/requires :api_key/, fn ->
        ReqLLMProvider.new(api_key_provider: :anthropic)
      end
    end

    test "offers host-confirmed fallbacks missing from the bundled catalog" do
      provider =
        ReqLLMProvider.new(
          api_key: "test-key",
          catalog_fallbacks: ["zai_coding_plan:future-catalog-canary"]
        )

      assert "zai_coding_plan:future-catalog-canary" in Provider.available_models(provider,
               scope: :zai_coding_plan,
               require: [chat: true, tools: true]
             )

      refute "zai_coding_plan:future-catalog-canary" in Provider.available_models(provider,
               scope: :anthropic,
               require: [chat: true, tools: true]
             )
    end

    test "fallbacks follow the canonical catalog so they do not become provider defaults" do
      provider =
        ReqLLMProvider.new(
          api_keys: %{zai_coding_plan: "coding-plan-key"},
          catalog_fallbacks: ["zai_coding_plan:future-catalog-canary"]
        )

      models =
        Provider.available_models(provider,
          scope: :zai_coding_plan,
          require: [chat: true, tools: true]
        )

      assert List.last(models) == "zai_coding_plan:future-catalog-canary"
      assert hd(models) != "zai_coding_plan:future-catalog-canary"
    end

    test "a fallback already discovered upstream does not override catalog ordering" do
      discovered =
        Provider.available_models(ReqLLMProvider.new(api_key: "test-key"),
          scope: :zai_coding_plan,
          require: [chat: true, tools: true]
        )

      canonical = hd(discovered)

      with_redundant_fallback =
        Provider.available_models(
          ReqLLMProvider.new(
            api_key: "test-key",
            catalog_fallbacks: [canonical]
          ),
          scope: :zai_coding_plan,
          require: [chat: true, tools: true]
        )

      assert with_redundant_fallback == discovered
    end

    test "does not advertise a catalog fallback when its provider has no credential" do
      provider =
        ReqLLMProvider.new(
          api_key: "",
          catalog_fallbacks: ["zai_coding_plan:future-catalog-canary"]
        )

      refute "zai_coding_plan:future-catalog-canary" in Provider.available_models(provider,
               scope: :zai_coding_plan,
               require: [chat: true, tools: true]
             )
    end

    test "rejects an unknown model before it becomes session configuration" do
      assert {:error, {:unknown_model, "nonsense", _hint}} =
               Provider.validate_model(ReqLLMProvider.new(), "nonsense", [])
    end

    test "providers without discovery or validation remain usable" do
      provider = Scripted.new([])

      assert Provider.available_models(provider) == []
      assert :ok = Provider.validate_model(provider, "test:anything", [])
      assert Provider.reasoning_efforts(provider, "test:anything") == []
    end

    test "reads canonical and legacy reasoning effort metadata from the model database" do
      provider = ReqLLMProvider.new()

      assert Provider.reasoning_efforts(provider, "anthropic:claude-sonnet-5") ==
               ["default", "low", "medium", "high", "xhigh", "max"]

      assert "minimal" in Provider.reasoning_efforts(provider, "openai:gpt-5")
      assert Provider.reasoning_efforts(provider, "openai:gpt-4o-mini") == []
    end
  end

  describe "price_at_list_rates/2" do
    # A usage map as req_llm normalises it and the adapter's json/1 leaves it:
    # string keys, both counts reported, consistent cache counts, unpriced.
    defp unpriced(fields) do
      Map.merge(
        %{
          "input_includes_cached" => true,
          "cache_read_tokens" => 0,
          "cache_write_tokens" => 0,
          "reasoning_tokens" => 0,
          "add_reasoning_to_cost" => false,
          "usage_reported" => %{"input" => true, "output" => true},
          "billing_usage_complete" => true,
          "pricing" => %{"status" => "unknown"}
        },
        fields
      )
    end

    defp rates(model) do
      {:ok, %{cost: cost}} = ReqLLM.model(model)
      cost
    end

    test "cached tokens counted inside OpenAI's input are priced at the cache-read rate" do
      model = "openai:gpt-6-luna"
      rates = rates(model)

      usage =
        unpriced(%{
          "input_tokens" => 2_000,
          "cache_read_tokens" => 500,
          "cached_tokens" => 500,
          "output_tokens" => 10
        })

      priced = ReqLLMProvider.price_at_list_rates(usage, model)

      assert priced["pricing"] == %{
               "status" => "list_rates",
               "currency" => "USD",
               "total" => priced["cost_usd"]
             }

      assert_in_delta priced["cost_usd"],
                      (1_500 * rates.input + 500 * rates.cache_read + 10 * rates.output) /
                        1_000_000,
                      1.0e-10

      assert Lemieux.Usage.cost_usd(priced) == priced["cost_usd"]
    end

    test "Anthropic's reads and writes beside the input count are priced at their own rates" do
      model = "anthropic:claude-sonnet-5"
      rates = rates(model)

      usage =
        unpriced(%{
          "input_tokens" => 1_000,
          "cache_read_tokens" => 500,
          "cache_write_tokens" => 100,
          "output_tokens" => 10,
          "input_includes_cached" => false
        })

      assert_in_delta ReqLLMProvider.price_at_list_rates(usage, model)["cost_usd"],
                      (1_000 * rates.input + 500 * rates.cache_read + 100 * rates.cache_write +
                         10 * rates.output) / 1_000_000,
                      1.0e-10
    end

    test "reasoning is priced as ReqLLM would price it" do
      # Gemini bills reasoning beside output at the output rate, and req_llm's
      # normaliser says so; OpenAI counts it inside output_tokens, so the
      # same count is not charged twice; DeepSeek publishes a reasoning rate.
      gemini = "google:gemini-3.1-pro-preview"

      thought =
        unpriced(%{"input_tokens" => 100, "output_tokens" => 20, "reasoning_tokens" => 50})

      assert_in_delta ReqLLMProvider.price_at_list_rates(
                        Map.put(thought, "add_reasoning_to_cost", true),
                        gemini
                      )["cost_usd"],
                      (100 * rates(gemini).input + 70 * rates(gemini).output) / 1_000_000,
                      1.0e-10

      openai = "openai:gpt-6-luna"

      assert_in_delta ReqLLMProvider.price_at_list_rates(thought, openai)["cost_usd"],
                      (100 * rates(openai).input + 20 * rates(openai).output) / 1_000_000,
                      1.0e-10

      deepseek = "deepseek:deepseek-v4-flash"
      assert is_number(rates(deepseek).reasoning)

      assert_in_delta ReqLLMProvider.price_at_list_rates(thought, deepseek)["cost_usd"],
                      (100 * rates(deepseek).input + 20 * rates(deepseek).output +
                         50 * rates(deepseek).reasoning) / 1_000_000,
                      1.0e-10
    end

    test "usage req_llm priced, or that is not whole, is left exactly as it came" do
      model = "openai:gpt-6-luna"
      whole = unpriced(%{"input_tokens" => 100, "output_tokens" => 20})

      priced_already = Map.put(whole, "total_cost", 0.01)
      assert ReqLLMProvider.price_at_list_rates(priced_already, model) == priced_already

      # A count the provider did not report, or cache counts that do not add
      # up: an unknown cost stays unknown instead of becoming a number, so a
      # capped session stops rather than spending against a wrong total.
      no_output = Map.put(whole, "usage_reported", %{"input" => true, "output" => false})
      assert ReqLLMProvider.price_at_list_rates(no_output, model) == no_output

      inconsistent = Map.put(whole, "billing_usage_complete", false)
      assert ReqLLMProvider.price_at_list_rates(inconsistent, model) == inconsistent
    end

    test "a model without usable list rates leaves the usage unpriced" do
      usage = unpriced(%{"input_tokens" => 100, "output_tokens" => 20})

      for model <- [
            # The -1,000,000 sentinel: a negative "price".
            "openrouter:openrouter/auto",
            # Priced in credits, with zero rates.
            "zai_coding_plan:glm-5.3",
            # Tariff components, but no flat rates at all.
            "anthropic:claude-3-haiku-20240307"
          ] do
        assert ReqLLMProvider.price_at_list_rates(usage, model) == usage, model
      end
    end
  end

  describe "cost estimation" do
    test "prices conservative input plus the requested maximum output" do
      small =
        request([Entry.new(:user, %{"text" => "hello"})], params: [max_tokens: 10])

      large =
        request([Entry.new(:user, %{"text" => "hello"})], params: [max_tokens: 1_000])

      small_cost = Provider.estimate_cost(ReqLLMProvider.new(), small)
      large_cost = Provider.estimate_cost(ReqLLMProvider.new(), large)

      assert is_number(small_cost)
      assert small_cost > 0
      assert large_cost > small_cost
    end

    test "reserves a realistic answer rather than the model's whole output limit" do
      # A Sonnet-class model may write 64K tokens; almost no agent turn does.
      # Reserving the limit priced every request near a dollar, and stopped a
      # $5 session after two or three turns that cost cents.
      model = "anthropic:claude-sonnet-4-5"
      {:ok, %{limits: %{output: limit}}} = ReqLLM.model(model)
      assert limit > 8_192

      question = [Entry.new(:user, %{"text" => "hello"})]
      provider = ReqLLMProvider.new()
      unset = Provider.estimate_cost(provider, Request.new(model, entries: question))

      reserved =
        Provider.estimate_cost(
          provider,
          Request.new(model, entries: question, params: [max_tokens: 8_192])
        )

      whole_limit =
        Provider.estimate_cost(
          provider,
          Request.new(model, entries: question, params: [max_tokens: limit])
        )

      assert unset == reserved
      assert unset < whole_limit / 4
    end

    test "grows the reservation with the largest answer the conversation has produced" do
      model = "anthropic:claude-sonnet-4-5"
      provider = ReqLLMProvider.new()
      question = Entry.new(:user, %{"text" => "write the module"})

      long_answer =
        Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "..."}]},
          usage: %{"input_tokens" => 100, "output_tokens" => 20_000}
        )

      fresh = Provider.estimate_cost(provider, Request.new(model, entries: [question]))

      after_long =
        Provider.estimate_cost(
          provider,
          Request.new(model, entries: [question, long_answer, question])
        )

      assert after_long > fresh
    end

    test "reads input from the last measured request rather than from bytes" do
      # A 400 KB paste is about 100K tokens by bytes; the provider measured it
      # at 1,000 (say it was mostly whitespace). The measurement wins.
      model = "anthropic:claude-haiku-4-5"
      provider = ReqLLMProvider.new()
      paste = Entry.new(:user, %{"text" => String.duplicate(" ", 400_000)})
      answer = fn usage -> Entry.new(:assistant, %{"content" => []}, usage: usage) end
      follow_up = Entry.new(:user, %{"text" => "and?"})

      unmeasured =
        Provider.estimate_cost(
          provider,
          Request.new(model,
            entries: [paste, answer.(nil), follow_up],
            params: [max_tokens: 100]
          )
        )

      measured =
        Provider.estimate_cost(
          provider,
          Request.new(model,
            entries: [
              paste,
              answer.(%{"input_tokens" => 1_000, "output_tokens" => 50}),
              follow_up
            ],
            params: [max_tokens: 100]
          )
        )

      assert measured < unmeasured / 10
    end

    test "prices the cache share the last request observed at the cached rate" do
      model = "anthropic:claude-haiku-4-5"
      provider = ReqLLMProvider.new()
      question = Entry.new(:user, %{"text" => "go on"})

      estimate = fn usage ->
        Provider.estimate_cost(
          provider,
          Request.new(model,
            entries: [question, Entry.new(:assistant, %{"content" => []}, usage: usage), question],
            params: [max_tokens: 100]
          )
        )
      end

      cold = estimate.(%{"input_tokens" => 100_000, "output_tokens" => 10})

      # Anthropic reports reads beside input_tokens.
      warm =
        estimate.(%{
          "input_tokens" => 10_000,
          "cache_read_tokens" => 90_000,
          "output_tokens" => 10
        })

      # OpenAI-style usage counts them inside it, and says so.
      warm_inside =
        estimate.(%{
          "input_tokens" => 100_000,
          "cache_read_tokens" => 90_000,
          "input_includes_cached" => true,
          "output_tokens" => 10
        })

      assert warm < cold / 2
      assert_in_delta warm_inside, warm, 0.000_1
    end

    test "unknown pricing is still unknown" do
      estimate = fn model ->
        Provider.estimate_cost(
          ReqLLMProvider.new(),
          Request.new(model, entries: [Entry.new(:user, %{"text" => "hi"})])
        )
      end

      assert estimate.("ollama:local-quantisation") == nil

      # Rates that are not a price are not a fallback either: OpenRouter's
      # routers carry -1,000,000 as a "priced by whatever answers" sentinel,
      # which would have made a cap impossible to reach; Z.AI's coding plan is
      # priced in credits, and its zero rates would have read as free.
      assert estimate.("openrouter:openrouter/auto") == nil
      assert estimate.("zai_coding_plan:glm-5.3") == nil
    end

    test "explicit pricing context survives provider defaults and request overrides" do
      ordinary = request([Entry.new(:user, %{"text" => "hello"})], params: [max_tokens: 100])
      realtime = Provider.estimate_cost(ReqLLMProvider.new(), ordinary)
      provider = ReqLLMProvider.new(pricing_context: %{api: "batch"})
      batch = Provider.estimate_cost(provider, ordinary)
      assert is_number(realtime)
      assert_in_delta batch, realtime / 2, 1.0e-10

      override = %{ordinary | params: [max_tokens: 100, pricing_context: %{api: "realtime"}]}
      assert Provider.estimate_cost(provider, override) == realtime

      # A context the tariff cannot be resolved for is priced at list rates,
      # which for this model are its realtime rates.
      unknown = %{ordinary | params: [max_tokens: 100, pricing_context: %{}]}
      assert_in_delta Provider.estimate_cost(provider, unknown), realtime, 2.0e-6
    end

    test "falls back to the model's list rates when ReqLLM cannot resolve its tariff" do
      # gpt-6-luna's catalog tariff carries service-tier modifiers (flex,
      # priority, data residency) that no pricing context resolves, so the
      # calculator answers nil and a metered session stopped before its first
      # request. The flat `cost` rates are the list price. If a ReqLLM or
      # llm_db update learns to price this tariff, move the test to a model it
      # still cannot: the fallback is what is under test.
      model = "openai:gpt-6-luna"
      {:ok, %{cost: %{input: input_rate, output: output_rate}} = catalog} = ReqLLM.model(model)

      probe = %{
        input_tokens: 10,
        output_tokens: 10,
        cached_tokens: 0,
        cache_creation_tokens: 0,
        input_includes_cached: true
      }

      assert {:ok, nil} = ReqLLM.Billing.calculate(probe, catalog, %{api: "realtime"})

      request =
        Request.new(model,
          entries: [Entry.new(:user, %{"text" => "hello"})],
          params: [max_tokens: 4_096]
        )

      input_tokens = max(div(Request.input_bytes(request), 4), 1)
      expected = (input_tokens * input_rate + 4_096 * output_rate) / 1_000_000

      assert_in_delta Provider.estimate_cost(ReqLLMProvider.new(), request), expected, 1.0e-9
    end
  end

  describe "live" do
    @describetag :live
    # Even when chosen by `path:LINE`; see `LemieuxTest.Spend.skip/0`.
    @describetag skip: LemieuxTest.Spend.skip()

    test "streams text deltas and terminal usage for a trivial prompt" do
      {:ok, _apps} = Application.ensure_all_started(:req_llm)
      parent = self()
      provider = ReqLLMProvider.new()

      request =
        Request.new("anthropic:claude-haiku-4-5",
          system: "Answer with exactly one word.",
          entries: [Entry.new(:user, %{"text" => "What colour is a clear midday sky?"})],
          params: [max_tokens: 64]
        )

      assert :ok = Provider.run(provider, request, &send(parent, {:event, &1}))

      events = drain([])

      assert Enum.any?(events, &match?({:text_delta, _}, &1))

      assert {:message, %{"content" => [%{"type" => "text", "text" => text}]}} =
               Enum.find(events, &match?({:message, _}, &1))

      assert text =~ ~r/blue/i

      assert {:usage, usage} = Enum.find(events, &match?({:usage, _}, &1))
      assert usage["input_tokens"] > 0
      assert usage["output_tokens"] > 0

      assert List.last(events) == {:done, :stop}
    end
  end

  defp drain(acc) do
    receive do
      {:event, event} -> drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp incompatible_remote_tool(keyword) do
    %RemoteTool{
      name: "choose",
      server: "fixture",
      description: "Choose one input.",
      schema: %{
        "type" => "object",
        keyword => [%{"required" => ["left"]}, %{"required" => ["right"]}]
      }
    }
  end
end
