defmodule LemieuxJevCompactionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias LemieuxJevCompaction, as: JevCompaction
  alias SystemOneSDK.Test

  @moduletag :tmp_dir

  setup %{tmp_dir: path} do
    runtime = :"jev_compaction_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Lemieux.Providers.Scripted.new([]),
        store: JSONL.new(path),
        model: "test:model",
        tools: [Lemieux.Tools.Read]
      )

    %{session: session, runtime: runtime, store: JSONL.new(path)}
  end

  test "extension installs applying compaction for a supplied Jev client", %{session: session} do
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.01}})

    {:ok, harness} =
      Lemieux.Harness.assemble(Lemieux.Harness.new(tools: [Lemieux.Tools.Read]), [
        {JevCompaction, client: client, preserve_recent_entries: 0}
      ])

    assert length(Keyword.get_values(harness.hooks, :prepare_next_turn)) == 1
    refute inspect(harness.applied) =~ "typesafe-test-key"
    {request, result} = request("read", String.duplicate("source line\n", 150))

    assert {:ok, projected} =
             Lemieux.Hooks.prepare_next_turn(harness.hooks, request, %{session: session})

    assert List.last(projected.entries).payload["output"] != result.payload["output"]
    assert List.last(projected.entries).payload["output"] =~ "rerun the tool"

    assert {:ok, %{value: %{"last_outcome" => "applied"}}} =
             Session.document(session, "jev_compaction")

    Test.verify!(client)
    Test.close(client)
  end

  test "compaction can be explicitly disabled with a configured Jev client" do
    client = Test.client()

    assert {:ok, harness} =
             Lemieux.Harness.assemble(Lemieux.Harness.new(), [
               {JevCompaction, client: client, enabled: false}
             ])

    assert Keyword.get_values(harness.hooks || [], :prepare_next_turn) == []
    Test.close(client)
  end

  test "without Jev access the extension installs no hook" do
    assert {:ok, harness} =
             Lemieux.Harness.assemble(Lemieux.Harness.new(), [
               {JevCompaction, api_key: ""}
             ])

    assert harness.hooks == nil

    assert {:error, {JevCompaction, "Jev access is unavailable"}} =
             Lemieux.Harness.assemble(Lemieux.Harness.new(), [
               {JevCompaction, api_key: "", enabled: true}
             ])
  end

  test "a pinned Ixway route builds a compatible SDK client and never falls back" do
    opts = [
      route: :ixway,
      ixway_endpoint: "http://localhost:4003",
      ixway_api_key: "gateway-test-key",
      api_key: "hosted-test-key",
      model: "jev-local-1"
    ]

    # Ixway is one more `POST /v1/systemone` service: it goes through the
    # SDK's generic endpoint provider, not TypeSafe's, so a gateway and a
    # declared provider share one code path.
    client = JevCompaction.client(opts)
    assert client.base_url == "http://localhost:4003"
    assert client.api_key == "gateway-test-key"
    assert client.default_model == "jev-local-1"
    assert client.provider == SystemOneSDK.Providers.Endpoint
    assert client.response_contract.allowed_models == ["jev-local-1"]
    assert JevCompaction.describe(opts)["provider"] == "ixway"

    missing = Keyword.put(opts, :ixway_api_key, "")
    assert JevCompaction.client(missing) == nil

    assert {:error, "Jev access is unavailable"} =
             JevCompaction.init(Keyword.put(missing, :enabled, true))
  end

  test "a declared provider builds an endpoint client for its URL, keyless when it has no key" do
    provider = %{
      name: "local",
      type: :endpoint,
      base_url: "http://127.0.0.1:8080/scorer",
      api_key: nil,
      headers: %{"X-Scorer-Tenant" => "team-a"},
      model: "jev-local-1"
    }

    client = JevCompaction.client(provider: provider)
    assert client.provider == SystemOneSDK.Providers.Endpoint
    assert client.base_url == "http://127.0.0.1:8080/scorer"
    assert client.api_key == nil
    assert client.default_model == "jev-local-1"
    assert client.headers["X-Scorer-Tenant"] == "team-a"
    assert client.response_contract.allowed_models == ["jev-local-1"]
    assert JevCompaction.describe(provider: provider)["provider"] == "local"

    # A service that wants the key in a header of its own gets it there, and
    # no bearer token.
    headed = Map.merge(provider, %{api_key: "private-header-key", api_key_header: "X-API-Key"})
    assert JevCompaction.client(provider: headed).api_key == nil
    assert JevCompaction.client(provider: headed).headers["X-API-Key"] == "private-header-key"
    assert JevCompaction.client(provider: headed).headers["X-Scorer-Tenant"] == "team-a"

    # The hosted service is the one provider with TypeSafe's client, default
    # model and published rates; a declared one is unpriced until told.
    hosted = %{provider | name: "typesafe", type: :typesafe, base_url: "https://api.typesafe.ai"}

    assert JevCompaction.client(provider: %{hosted | api_key: "hosted-test-key", model: nil}).default_model ==
             "jev-1.13.0"

    assert JevCompaction.client(provider: %{hosted | api_key: "hosted-test-key", model: nil}).provider ==
             SystemOneSDK.Providers.TypeSafe

    assert JevCompaction.client(provider: %{hosted | api_key: nil}) == nil
    assert JevCompaction.client(provider: %{provider | model: nil}) == nil

    assert JevCompaction.client(provider: %{provider | base_url: "http://user:secret@host"}) ==
             nil

    assert {:error, "Jev access is unavailable"} =
             JevCompaction.init(provider: %{provider | model: nil}, enabled: true)

    assert_raise ArgumentError, ~r/:provider must be a map/, fn ->
      JevCompaction.hook(provider: %{name: "local"})
    end
  end

  test "a declared provider without a declared tariff is skipped under a dollar cap", %{
    runtime: runtime,
    store: store
  } do
    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Lemieux.Providers.Scripted.new([]),
        store: store,
        model: "test:model",
        max_cost_usd: 0.01,
        tools: [Lemieux.Tools.Read]
      )

    {request, _result} = request("read", String.duplicate("source line\n", 500))

    opts = [
      provider: %{
        name: "local",
        type: :endpoint,
        # Nothing listens here; a request would fail loudly rather than quietly.
        base_url: "http://127.0.0.1:9",
        api_key: nil,
        headers: %{},
        model: "jev-local-1"
      },
      preserve_recent_entries: 0,
      min_result_chars: 1,
      reservation_per_call_usd: 0.005
    ]

    assert {:ok, ^request} = JevCompaction.prepare(request, %{session: session}, opts)
    assert {:ok, %{value: nil}} = Session.document(session, "jev_compaction")
    assert Session.budget(session).spent_usd == 0
  end

  test "auto selects the pinned Ixway route before hosted Jev" do
    client =
      JevCompaction.client(
        route: :auto,
        ixway_endpoint: "http://localhost:4003",
        ixway_api_key: "gateway-test-key",
        api_key: "hosted-test-key",
        model: "jev-local-1"
      )

    assert client.base_url == "http://localhost:4003"
    assert client.api_key == "gateway-test-key"
  end

  test "SDK decisions elide old read results in the send view and persist for later turns", %{
    session: session
  } do
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.01}}, usage: %{input_tokens: 51, output_tokens: 1})
    {request, result} = request("read", String.duplicate("source line\n", 500))
    hook = JevCompaction.hook(options(client))

    assert {:ok, projected} = hook.(request, %{session: session})
    assert length(projected.entries) == length(request.entries)
    assert List.last(projected.entries).payload["call_id"] == "call-1"
    assert List.last(projected.entries).payload["output"] =~ "rerun the tool"
    refute List.last(projected.entries).payload["output"] == result.payload["output"]
    assert result.payload["output"] == String.duplicate("source line\n", 500)

    assert {:ok, %{value: document}} = Session.document(session, "jev_compaction")
    assert document["elisions"][result.id] =~ ~r/\A[0-9a-f]{64}\z/

    assert document["last_usage"] == %{
             "model" => "jev-latest",
             "input_tokens" => 51,
             "output_tokens" => 1
           }

    assert [%{"mode" => "apply", "candidates" => [candidate]} = evaluation] =
             document["evaluations"]

    assert evaluation["sdk_usage"] == document["last_usage"]
    assert candidate["entry_id"] == result.id
    assert candidate["keep_probability"] == 0.01
    assert candidate["estimated_saved_tokens"] > 1_000
    assert is_integer(document["last_latency_ms"]) and document["last_latency_ms"] >= 0

    assert {:ok, repeated} = hook.(request, %{session: session})

    assert List.last(repeated.entries).payload["output"] ==
             List.last(projected.entries).payload["output"]

    unavailable = %{request | tools: []}
    assert {:ok, ^unavailable} = hook.(unavailable, %{session: session})

    changed = %{
      request
      | entries:
          List.update_at(request.entries, 2, fn entry ->
            %{
              entry
              | payload: Map.put(entry.payload, "output", String.duplicate("changed\n", 500))
            }
          end)
    }

    assert {:ok, ^changed} = hook.(changed, %{session: session})

    assert [sdk_request] = Test.requests(client)
    sdk_body = IO.iodata_to_binary(sdk_request.body)
    assert sdk_body =~ "Find the implementation"
    refute sdk_body =~ "source line"
    refute inspect(document) =~ "typesafe-test-key"
    Test.verify!(client)
    Test.close(client)
  end

  test "shadow mode records reusable scores without changing the send view", %{session: session} do
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.02}}, usage: %{input_tokens: 23, output_tokens: 1})
    {request, result} = request("read", String.duplicate("source line\n", 500))
    hook = JevCompaction.hook(Keyword.put(options(client), :mode, :shadow))

    assert {:ok, ^request} = hook.(request, %{session: session})
    assert {:ok, %{value: document}} = Session.document(session, "jev_compaction")
    assert document["elisions"] == %{}
    assert document["last_outcome"] == "shadow"
    assert document["last_saved_tokens_estimate"] == 0
    assert [%{"mode" => "shadow", "candidates" => [candidate]}] = document["evaluations"]
    assert candidate["entry_id"] == result.id
    assert candidate["keep_probability"] == 0.02
    assert candidate["estimated_saved_tokens"] > 1_000
    assert document["last_hypothetical_saved_tokens"] > 1_000
    refute inspect(document) =~ "source line"

    assert {:ok, ^request} = hook.(request, %{session: session})
    assert length(Test.requests(client)) == 1
    Test.verify!(client)
    Test.close(client)
  end

  test "a later prompt reuses an applied elision without scoring its marker", %{session: session} do
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.01}})
    {request, _result} = request("read", String.duplicate("source line\n", 500))
    hook = JevCompaction.hook(Keyword.put(options(client), :max_evaluations, 2))

    assert {:ok, first} = hook.(request, %{session: session})
    later = %{request | entries: request.entries ++ [Entry.new(:user, %{"text" => "Next task"})]}
    assert {:ok, second} = hook.(later, %{session: session})

    assert Enum.at(first.entries, 2).payload["output"] ==
             Enum.at(second.entries, 2).payload["output"]

    assert length(Test.requests(client)) == 1
    Test.verify!(client)
    Test.close(client)
  end

  test "recent results and non-reproducible tools remain untouched", %{session: session} do
    client = Test.client()
    hook = JevCompaction.hook(Keyword.put(options(client), :preserve_recent_entries, 3))
    {recent, _result} = request("read", String.duplicate("a", 2_000))
    assert {:ok, ^recent} = hook.(recent, %{session: session})

    hook = JevCompaction.hook(options(client))
    {bash, _result} = request("bash", String.duplicate("a", 2_000))
    assert {:ok, ^bash} = hook.(bash, %{session: session})

    {instructions, _result} = request("read", String.duplicate("a", 2_000))

    instructions = %{
      instructions
      | entries:
          List.update_at(instructions.entries, 2, fn entry ->
            payload =
              Map.put(
                entry.payload,
                "arguments",
                Map.put(entry.payload["arguments"], "path", "AGENTS.md")
              )

            %{entry | payload: payload}
          end)
    }

    assert {:ok, ^instructions} = hook.(instructions, %{session: session})
    assert Test.requests(client) == []
    Test.close(client)
  end

  test "an old necessary read is preserved when Jev assigns a high keep score", %{
    session: session
  } do
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.95}})
    {request, result} = request("read", String.duplicate("required fact\n", 500))

    assert {:ok, ^request} = JevCompaction.prepare(request, %{session: session}, options(client))
    assert List.last(request.entries).payload["output"] == result.payload["output"]

    assert {:ok, %{value: %{"last_outcome" => "insufficient", "elisions" => %{}}}} =
             Session.document(session, "jev_compaction")

    assert length(Test.requests(client)) == 1
    Test.verify!(client)
    Test.close(client)
  end

  test "malformed SDK answers leave the request unchanged", %{session: session} do
    client = Test.client()
    Test.stub_response(client, %{"model" => "jev-1.13.0", "answers" => %{}})
    {request, _result} = request("read", String.duplicate("a", 2_000))

    assert {:ok, ^request} = JevCompaction.prepare(request, %{session: session}, options(client))

    assert {:ok, %{value: %{"attempts" => 1, "elisions" => %{}}}} =
             Session.document(session, "jev_compaction")

    Test.verify!(client)
    Test.close(client)
  end

  test "a small projected saving is rejected after the SDK call", %{session: session} do
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.01}})
    {request, _result} = request("read", String.duplicate("a", 2_000))
    opts = Keyword.put(options(client), :min_saved_tokens, 10_000)

    assert {:ok, ^request} = JevCompaction.prepare(request, %{session: session}, opts)

    assert {:ok, %{value: %{"last_outcome" => "insufficient", "elisions" => %{}}}} =
             Session.document(session, "jev_compaction")

    assert length(Test.requests(client)) == 1
    Test.verify!(client)
    Test.close(client)
  end

  test "Jev usage is visible to the host and a reserved local cap stops later calls", %{
    session: session
  } do
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.01}}, usage: %{input_tokens: 100, output_tokens: 2})
    {request, _result} = request("read", String.duplicate("source line\n", 500))

    opts =
      Keyword.merge(options(client),
        mode: :shadow,
        max_evaluations: 2,
        max_cost_usd: 0.003,
        reservation_per_call_usd: 0.003,
        input_per_million: 1.0,
        output_per_million: 0.0
      )

    assert {:ok, ^request} = JevCompaction.prepare(request, %{session: session}, opts)
    assert {:ok, %{value: document}} = Session.document(session, "jev_compaction")
    assert_in_delta document["spent_usd"], 0.0001, 0.00000001
    assert_in_delta Session.budget(session).spent_usd, 0.0001, 0.00000001
    assert Session.snapshot(session).usage.direct["input_tokens"] == 100
    refute Session.snapshot(session).context.measured?

    later = %{request | entries: request.entries ++ [Entry.new(:user, %{"text" => "Later"})]}
    assert {:ok, ^later} = JevCompaction.prepare(later, %{session: session}, opts)
    assert length(Test.requests(client)) == 1
    Test.verify!(client)
    Test.close(client)
  end

  test "a capped host skips Jev until its call has a budget reservation", %{
    runtime: runtime,
    store: store
  } do
    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Lemieux.Providers.Scripted.new([]),
        store: store,
        model: "test:model",
        max_cost_usd: 0.01,
        tools: [Lemieux.Tools.Read]
      )

    client = Test.client()
    {request, _result} = request("read", String.duplicate("source line\n", 500))
    assert {:ok, ^request} = JevCompaction.prepare(request, %{session: session}, options(client))
    assert Test.requests(client) == []

    Test.stub(client, %{"keep_1" => {:noul, 0.01}}, usage: %{input_tokens: 30, output_tokens: 1})

    opts =
      Keyword.merge(options(client),
        reservation_per_call_usd: 0.005,
        input_per_million: 0.04,
        output_per_million: 0.0
      )

    assert {:ok, projected} = JevCompaction.prepare(request, %{session: session}, opts)
    assert projected != request
    assert_in_delta Session.budget(session).spent_usd, 30 * 0.04 / 1_000_000, 1.0e-12
    Test.verify!(client)
    Test.close(client)
  end

  test "an SDK exception cannot deny the pending model request", %{session: session} do
    client = Test.client()
    Test.stub_callback(client, fn _request -> raise "sensitive SDK failure" end)
    {request, _result} = request("read", String.duplicate("a", 2_000))

    assert {:ok, ^request} = JevCompaction.prepare(request, %{session: session}, options(client))

    assert {:ok, %{value: %{"last_outcome" => "failed", "attempts" => 1}}} =
             Session.document(session, "jev_compaction")

    Test.verify!(client)
    Test.close(client)
  end

  test "the prepared model turn uses the projection while the session transcript keeps full output",
       %{
         runtime: runtime,
         store: store,
         tmp_dir: path
       } do
    File.write!(Path.join(path, "large.txt"), String.duplicate("source line\n", 500))
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.01}})

    provider =
      Lemieux.Providers.Scripted.new([
        [
          {:tool_call, %{id: "read-1", name: "read", arguments: %{"path" => "large.txt"}}},
          {:done, :tool_calls}
        ],
        [{:text_delta, "done"}, {:done, :stop}]
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: store,
        model: "test:model",
        cwd: path,
        context_window: 1_000_000,
        tools: [Lemieux.Tools.Read],
        subscriber: self(),
        hooks: [prepare_next_turn: JevCompaction.hook(options(client))]
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "Read the large file")
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

    assert [_first, second] = Lemieux.Providers.Scripted.requests(provider)

    assert [%Entry{payload: %{"output" => sent_output}}] =
             Enum.filter(second.entries, &(&1.type == :tool_result))

    assert sent_output =~ "rerun the tool"

    assert [%Entry{payload: %{"output" => stored_output}}] =
             Session.snapshot(session).entries
             |> Enum.filter(&(&1.type == :tool_result))

    assert stored_output =~ "source line"
    assert byte_size(stored_output) > byte_size(sent_output)
    assert length(Test.requests(client)) == 1

    :ok =
      DynamicSupervisor.terminate_child(
        Lemieux.Supervisor.session_supervisor(runtime),
        session
      )

    resumed_provider =
      Lemieux.Providers.Scripted.new([[{:text_delta, "resumed"}, {:done, :stop}]])

    {:ok, resumed} =
      Lemieux.resume_session(
        supervisor: runtime,
        provider: resumed_provider,
        store: store,
        resume: id,
        cwd: path,
        hooks: [prepare_next_turn: JevCompaction.hook(options(client))],
        subscriber: self()
      )

    :ok = Session.prompt(resumed, "Continue")
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000
    assert [resumed_request] = Lemieux.Providers.Scripted.requests(resumed_provider)

    assert [%Entry{payload: %{"output" => resumed_output}}] =
             Enum.filter(resumed_request.entries, &(&1.type == :tool_result))

    assert resumed_output == sent_output
    assert length(Test.requests(client)) == 1
    Test.verify!(client)
    Test.close(client)
  end

  defp options(client) do
    [
      client: client,
      activation_tokens: 1,
      preserve_recent_entries: 0,
      min_result_chars: 1,
      min_saved_tokens: 1,
      max_evaluations: 1
    ]
  end

  defp request(tool, output) do
    user = Entry.new(:user, %{"text" => "Find the implementation"})

    assistant =
      Entry.new(:assistant, %{
        "content" => [],
        "tool_calls" => [%{"id" => "call-1", "name" => tool, "arguments" => %{"path" => "a.ex"}}]
      })

    result =
      Entry.new(:tool_result, %{
        "call_id" => "call-1",
        "name" => tool,
        "arguments" => %{"path" => "a.ex"},
        "output" => output,
        "error" => false
      })

    {%Request{
       model: "test:model",
       entries: [user, assistant, result],
       tools: [Lemieux.Tools.Read]
     }, result}
  end
end
