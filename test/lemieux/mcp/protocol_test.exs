defmodule Lemieux.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Lemieux.MCP.Protocol
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.Tool.Result

  describe "building a request" do
    test "a modern request carries its protocol version, identity and capabilities" do
      request = Protocol.request(:modern, "tools/list", %{}, id: 1)

      assert request["jsonrpc"] == "2.0"
      assert request["id"] == 1
      assert request["method"] == "tools/list"

      meta = request["params"]["_meta"]
      assert meta["io.modelcontextprotocol/protocolVersion"] == Protocol.modern_version()
      assert meta["io.modelcontextprotocol/clientInfo"]["name"] == "lemieux"
      assert is_map(meta["io.modelcontextprotocol/clientCapabilities"])
    end

    # There is no handshake to carry it, so every request states its own
    # version. Leaving it off is what an older client looks like to a modern
    # server, and gets the request rejected.
    test "a modern request states a version it was told to use" do
      request = Protocol.request(:modern, "tools/list", %{}, id: 1, version: "2027-01-01")

      assert request["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] ==
               "2027-01-01"
    end

    test "a legacy request carries no metadata at all" do
      request = Protocol.request(:legacy, "tools/list", %{}, id: 1)

      assert request["params"] == %{}
      refute request["params"]["_meta"]
    end

    test "params are preserved alongside the metadata" do
      request = Protocol.request(:modern, "tools/call", %{"name" => "echo"}, id: 2)

      assert request["params"]["name"] == "echo"
      assert request["params"]["_meta"]
    end

    test "a notification has no id, because nothing answers it" do
      assert Protocol.notification("notifications/initialized") == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             }
    end
  end

  describe "telling one era from the other" do
    # The spec's rule, and the whole of backward compatibility: a recognised
    # modern error means a modern server that disagrees about versions; anything
    # else means a server that has never heard of `server/discover`.
    test "an unsupported-version error is a modern server disagreeing" do
      error = %{
        "code" => -32_022,
        "message" => "Unsupported protocol version",
        "data" => %{"supported" => ["2026-07-28", "2025-11-25"], "requested" => "1900-01-01"}
      }

      assert Protocol.classify(error) == {:modern, ["2026-07-28", "2025-11-25"]}
    end

    test "a method-not-found error is a server from before all this" do
      assert Protocol.classify(%{"code" => -32_601, "message" => "Method not found"}) == :legacy
    end

    test "an unrecognised error is treated as legacy, which is the recoverable guess" do
      assert Protocol.classify(%{"code" => -1, "message" => "what?"}) == :legacy
    end
  end

  describe "choosing a version" do
    test "prefers the newest revision both sides speak" do
      assert Protocol.choose(["2026-07-28", "2025-11-25"]) == {:ok, "2026-07-28"}
      assert Protocol.choose(["2025-11-25", "2025-06-18"]) == {:ok, "2025-11-25"}
    end

    test "says so when there is nothing in common" do
      assert {:error, message} = Protocol.choose(["1900-01-01"])
      assert message =~ "1900-01-01"
    end
  end

  describe "reading a tools/list result" do
    test "normalises a tool into something a session can dispatch" do
      result = %{
        "resultType" => "complete",
        "tools" => [
          %{
            "name" => "get_weather",
            "title" => "Weather",
            "description" => "Get the weather",
            "inputSchema" => %{"type" => "object", "properties" => %{}},
            "outputSchema" => %{"type" => "object", "properties" => %{"temp" => %{}}},
            "annotations" => %{"readOnlyHint" => true},
            "_meta" => %{"publisher" => "fixture"}
          }
        ],
        "ttlMs" => 300_000
      }

      assert {:ok, [%RemoteTool{} = tool], nil} = Protocol.tools(result)
      assert tool.name == "get_weather"
      assert tool.description == "Get the weather"
      assert tool.schema == %{"type" => "object", "properties" => %{}}
      assert tool.output_schema == %{"type" => "object", "properties" => %{"temp" => %{}}}
      assert tool.annotations == %{"readOnlyHint" => true}
      assert tool.meta == %{"publisher" => "fixture"}
    end

    test "reports the cursor when there is another page" do
      result = %{"tools" => [], "nextCursor" => "page-2"}

      assert {:ok, [], "page-2"} = Protocol.tools(result)
    end

    # A tool with no schema is one the model cannot be told how to call.
    test "a tool without a usable schema is left out rather than offered broken" do
      result = %{"tools" => [%{"name" => "broken"}, %{"name" => "fine", "inputSchema" => %{}}]}

      assert {:ok, [tool], nil} = Protocol.tools(result)
      assert tool.name == "fine"
    end
  end

  describe "reading a tools/call result" do
    test "joins text content into the output the model reads" do
      result = %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => "it is 72F"}],
        "isError" => false
      }

      assert {:ok, %Result{model_text: "it is 72F"}} = Protocol.output(result)
    end

    test "several content blocks are joined in order" do
      result = %{
        "content" => [
          %{"type" => "text", "text" => "first"},
          %{"type" => "text", "text" => "second"}
        ]
      }

      assert {:ok, %Result{model_text: "first\nsecond"}} = Protocol.output(result)
    end

    # The spec is explicit that these should reach the model: they are what it
    # needs to correct itself.
    test "a tool execution error is an error the model can read" do
      result = %{
        "content" => [%{"type" => "text", "text" => "date must be in the future"}],
        "isError" => true
      }

      assert {:error, %Result{model_text: "date must be in the future"}} =
               Protocol.output(result)
    end

    test "content that is not text is described rather than dropped silently" do
      result = %{"content" => [%{"type" => "image", "mimeType" => "image/png"}]}

      assert {:ok, %Result{} = output} = Protocol.output(result)
      assert output.model_text =~ "image"
      assert output.content == [%{"type" => "image", "mimeType" => "image/png"}]
    end

    test "structured content comes through when there is no text to read" do
      result = %{"content" => [], "structuredContent" => %{"temperature" => 22.5}}

      assert {:ok, %Result{} = output} = Protocol.output(result)
      assert output.model_text =~ "22.5"
      assert output.structured_content == %{"temperature" => 22.5}
    end

    test "a result with nothing in it says so rather than returning blankness" do
      assert {:ok, %Result{} = output} = Protocol.output(%{"content" => []})
      assert output.model_text =~ "no output"
    end

    # The server has not answered yet: it is asking for something first. The
    # caller satisfies what it can and retries, echoing the state back.
    test "an input_required result is reported as such, not as an answer" do
      requests = %{
        "who" => %{
          "method" => "elicitation/create",
          "params" => %{"mode" => "form", "message" => "who are you?"}
        }
      }

      result = %{
        "resultType" => "input_required",
        "inputRequests" => requests,
        "requestState" => "opaque"
      }

      assert {:input_required, ^requests, "opaque"} = Protocol.output(result)
    end

    test "a request for nothing in particular still carries its state" do
      result = %{"resultType" => "input_required", "requestState" => "opaque"}

      assert {:input_required, %{}, "opaque"} = Protocol.output(result)
    end

    # Required by the spec: earlier-protocol servers omit the field entirely.
    test "a result from an older server, with no resultType, is complete" do
      result = %{"content" => [%{"type" => "text", "text" => "fine"}]}

      assert {:ok, %Result{model_text: "fine"}} = Protocol.output(result)
    end
  end

  describe "namespacing" do
    # Two servers may each expose `search`; the spec tells clients aggregating
    # them to disambiguate, and the model only ever sees the namespaced name.
    test "a remote tool is offered under its server's name" do
      tool = %RemoteTool{name: "search", server: "github", description: "d", schema: %{}}

      assert RemoteTool.qualified_name(tool) == "github__search"
    end

    # MCP allows dots in a tool name; providers do not, and req_llm raises on
    # one — which used to fail every request of the session, MCP or not.
    test "a name no provider accepts is rewritten, keeping its server prefix" do
      tool = %RemoteTool{name: "admin.tools.list", server: "gh", description: "d", schema: %{}}

      name = RemoteTool.qualified_name(tool)

      assert name =~ ~r/\Agh__admin_tools_list_[0-9a-f]{6}\z/
      assert ReqLLM.Tool.valid_name?(name)
    end

    # The hash is what keeps two originals that sanitise alike apart; without
    # it, a call for one would be routed to the other.
    test "two originals that sanitise alike are offered under different names" do
      dotted = %RemoteTool{name: "files.read", server: "fs", description: "d", schema: %{}}
      underscored = %RemoteTool{name: "files_read", server: "fs", description: "d", schema: %{}}

      assert RemoteTool.qualified_name(underscored) == "fs__files_read"
      refute RemoteTool.qualified_name(dotted) == RemoteTool.qualified_name(underscored)
    end

    test "a name longer than a provider allows is shortened to fit, deterministically" do
      tool = %RemoteTool{
        name: String.duplicate("very_long_tool_name_", 5),
        server: "server",
        description: "d",
        schema: %{}
      }

      name = RemoteTool.qualified_name(tool)

      assert byte_size(name) == 64
      assert ReqLLM.Tool.valid_name?(name)
      assert name == RemoteTool.qualified_name(tool)
    end

    test "a server name that starts with a digit or holds spaces still yields a valid name" do
      for server <- ["1st server", "-lead", "tidy up", "émoji✨"] do
        tool = %RemoteTool{name: "run", server: server, description: "d", schema: %{}}
        assert ReqLLM.Tool.valid_name?(RemoteTool.qualified_name(tool)), server
      end
    end

    test "assign_names settles collisions across servers and reports each rewrite" do
      dotted = %RemoteTool{name: "search", server: "my.docs", description: "d", schema: %{}}
      plain = %RemoteTool{name: "search", server: "my_docs", description: "d", schema: %{}}

      duplicate = %RemoteTool{
        name: "search",
        server: "my_docs",
        description: "again",
        schema: %{}
      }

      assert {[first, second], notices} = RemoteTool.assign_names([dotted, plain, duplicate])

      names = [RemoteTool.qualified_name(first), RemoteTool.qualified_name(second)]
      assert length(Enum.uniq(names)) == 2
      assert Enum.all?(names, &ReqLLM.Tool.valid_name?/1)
      assert Enum.any?(notices, &(&1 =~ "from my.docs is offered to the model as"))
    end
  end

  describe "tool listings" do
    test "a schema without a type is read as the object the specification requires" do
      result = %{"tools" => [%{"name" => "t", "inputSchema" => %{"properties" => %{}}}]}

      assert {:ok, [tool], nil, []} = Protocol.tools_report(result, "srv")
      assert tool.schema == %{"type" => "object", "properties" => %{}}
    end

    test "a tool whose arguments are not an object is left out, with a reason" do
      result = %{
        "tools" => [
          %{"name" => "bad", "inputSchema" => %{"type" => "string"}},
          %{"name" => "good", "inputSchema" => %{"type" => "object"}}
        ]
      }

      assert {:ok, [%RemoteTool{name: "good"}], nil, [problem]} =
               Protocol.tools_report(result, "srv")

      assert problem =~ ~s("bad")
      assert problem =~ "srv"
    end
  end

  describe "prompts and resources" do
    test "prompts keep the server's shape, and nameless entries are dropped" do
      result = %{
        "prompts" => [
          %{"name" => "review", "arguments" => [%{"name" => "path"}, %{"oops" => 1}]},
          %{"description" => "no name"}
        ],
        "nextCursor" => "p2"
      }

      assert {:ok, [prompt], "p2"} = Protocol.prompts(result)
      assert prompt["arguments"] == [%{"name" => "path"}]
    end

    test "a prompt is flattened into the text a person would send, naming what cannot be shown" do
      result = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Please review a.ex"}},
          %{"role" => "user", "content" => %{"type" => "image", "data" => ""}}
        ]
      }

      text = Protocol.prompt_text(result)
      assert text =~ "Please review a.ex"
      assert text =~ "[image content, which lemieux cannot show you]"
    end

    test "resource contents are text, and binary contents are named rather than decoded" do
      result = %{
        "contents" => [
          %{"uri" => "a://notes", "text" => "remember"},
          %{"uri" => "a://logo", "mimeType" => "image/png", "blob" => "iVBORw0KGgo="}
        ]
      }

      text = Protocol.resource_text(result)
      assert text =~ "remember"
      assert text =~ "image/png content at a://logo"
      refute text =~ "iVBOR"
    end
  end

  describe "requests" do
    test "a modern request keeps the _meta the caller put in its params" do
      request =
        Protocol.request(:modern, "tools/call", %{"_meta" => %{"progressToken" => 7}}, id: 7)

      assert request["params"]["_meta"]["progressToken"] == 7
      assert request["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"]
    end
  end
end
