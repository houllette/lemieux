defmodule Lemieux.CLI.ProviderMuxTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.ProviderMux
  alias Lemieux.Extensions.Delegation
  alias Lemieux.Ixway
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias LemieuxTest.HTTPFixture

  @moduletag :tmp_dir

  test "a session offers both configured routes and only their own models", %{tmp_dir: dir} do
    runtime = :"lemieux_mux_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    provider =
      ProviderMux.new(
        [{"ixway", ixway_provider()}],
        ReqLLM.new(api_keys: %{"openai" => "test-key", "anthropic" => "anthropic-key"})
      )

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(dir),
        provider: provider,
        model: "ixway:team/coding",
        tools: [],
        subscriber: self()
      )

    assert "ixway" in Session.available_providers(session)
    assert "openai" in Session.available_providers(session)
    assert "anthropic" in Session.available_providers(session)
    assert Session.available_models(session, "ixway") == ["ixway:team/coding"]

    assert Session.model_metadata(session) == %{
             "ixway:team/coding" => %{kind: nil, route: "Automatic"}
           }

    openai_models = Session.available_models(session, "openai")
    assert "openai:gpt-4o-mini" in openai_models
    assert Enum.all?(openai_models, &String.starts_with?(&1, "openai:"))

    assert Enum.all?(
             Session.available_models(session, "anthropic"),
             &String.starts_with?(&1, "anthropic:")
           )

    assert {:ok, selected} = Session.set_provider(session, "openai")
    assert String.starts_with?(selected, "openai:")
    assert {:ok, "ixway:team/coding"} = Session.set_provider(session, "ixway")
    assert {:error, {:provider_unavailable, "google"}} = Session.set_provider(session, "google")
  end

  test "Ixway selections stay on Ixway and cannot fall back to a direct key" do
    provider =
      ProviderMux.new(
        [{"ixway", ixway_provider()}],
        ReqLLM.new(api_keys: %{"openai" => "test-key"})
      )

    assert {:error, %Ixway.Error{reason: :model_not_available}} =
             Provider.validate_model(provider, "ixway:missing", [])

    assert {:error, %Ixway.Error{reason: :model_not_available}} =
             Provider.run(provider, Request.new("ixway:missing"), fn _event -> :ok end)

    assert :ok = Provider.validate_model(provider, "openai:gpt-4o-mini", [])
    refute inspect(provider) =~ "test-key"
    refute inspect(provider) =~ "gateway-key"
  end

  test "an Ixway startup failure is not replaced with a direct model" do
    ixway = Ixway.provider(endpoint: "https://gateway.example")

    provider =
      ProviderMux.new([{"ixway", ixway}], ReqLLM.new(api_keys: %{"openai" => "test-key"}))

    assert {:error, %Ixway.Error{reason: :api_key_required}} =
             ProviderMux.prepare(provider, "ixway:@default")

    assert {:ok, ^provider, "openai:gpt-4o-mini"} =
             ProviderMux.prepare(provider, "openai:gpt-4o-mini")
  end

  test "a selected direct model sends its own key to its own endpoint" do
    parent = self()

    {endpoint, listener, server} =
      HTTPFixture.server(fn headers, body, _socket ->
        send(parent, {:direct_request, headers["authorization"], JSON.decode!(body)["model"]})

        %{
          status: 200,
          headers: [{"content-type", "text/event-stream"}],
          body:
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        }
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    direct = ReqLLM.new(api_keys: %{"openai" => "direct-key"}, base_url: endpoint <> "/v1")
    provider = ProviderMux.new([{"ixway", ixway_provider()}], direct)

    assert :ok = Provider.run(provider, Request.new("openai:gpt-4o-mini"), fn _ -> :ok end)
    assert_receive {:direct_request, "Bearer direct-key", "gpt-4o-mini"}
  end

  describe "a route an extension registered" do
    alias LemieuxTest.StaticRoute

    @sse ~s|data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n|

    defp relay(attrs) do
      ReqLLM.new(
        route:
          {StaticRoute,
           StaticRoute.new(
             [name: "relay", models: ["qwen", "glm"], api_key: "relay-key", owner: self()] ++
               attrs
           )}
      )
    end

    defp relay_server(requests) do
      parent = self()

      {endpoint, listener, server} =
        HTTPFixture.server(
          fn headers, body, _socket ->
            send(parent, {:relay_request, headers["authorization"], JSON.decode!(body)["model"]})
            %{status: 200, headers: [{"content-type", "text/event-stream"}], body: @sse}
          end,
          requests: requests
        )

      on_exit(fn ->
        Process.exit(server, :kill)
        :gen_tcp.close(listener)
      end)

      endpoint
    end

    test "is prepared, listed and dispatched under its own name, and never falls back" do
      direct = ReqLLM.new(api_keys: %{"openai" => "direct-key"})
      relay = relay(default: "relay:qwen", endpoint: relay_server(2), window: 8_000)
      mux = ProviderMux.new([{"relay", relay}], direct)

      assert ProviderMux.route_names(mux) == ["relay"]
      assert {:ok, prepared, "relay:qwen"} = ProviderMux.prepare(mux, "relay:@default")
      assert_received {:route_ready, "relay"}

      assert {:ok, ^prepared, "openai:gpt-4o-mini"} =
               ProviderMux.prepare(prepared, "openai:gpt-4o-mini")

      assert Provider.available_models(prepared, provider: "relay") == ["relay:qwen", "relay:glm"]
      assert Provider.available_models(prepared, provider: :relay) == ["relay:qwen", "relay:glm"]
      openai = Provider.available_models(prepared, provider: "openai")
      assert "openai:gpt-4o-mini" in openai
      assert Enum.all?(openai, &String.starts_with?(&1, "openai:"))
      assert Enum.take(Provider.available_models(prepared), 2) == ["relay:qwen", "relay:glm"]

      assert Provider.model_metadata(prepared)["relay:qwen"] == %{kind: "static"}
      assert Provider.context_window(prepared, "relay:qwen") == 8_000
      assert Provider.estimate_cost(prepared, Request.new("relay:qwen")) == nil
      assert Provider.input_modalities(prepared, "relay:qwen") == :unknown

      assert Provider.input_modalities(prepared, "openai:gpt-4o-mini") ==
               Provider.input_modalities(direct, "openai:gpt-4o-mini")

      assert {:error, {:unknown_model, "relay:missing"}} =
               Provider.validate_model(prepared, "relay:missing", [])

      assert {:error, {:unknown_model, "relay:missing"}} =
               Provider.run(prepared, Request.new("relay:missing"), fn _ -> :ok end)

      assert :ok = Provider.run(prepared, Request.new("relay:qwen"), fn _ -> :ok end)
      assert_receive {:relay_request, "Bearer relay-key", "qwen"}
      assert_received {:route_target, "relay:qwen"}

      assert ProviderMux.child(prepared, "openai:gpt-4o-mini") == direct
      assert {ReqLLM, _} = relay_child = ProviderMux.child(prepared, "relay:qwen")
      refute inspect(ReqLLM.route(relay_child)) =~ "relay-key"
      refute inspect(prepared) =~ "direct-key"

      # Session parameters cross to the route, which lets only generation
      # settings through: a destination or a key among them changes nothing.
      hijack =
        Request.new("relay:qwen",
          params: [base_url: "http://127.0.0.1:9/v1", api_key: "stolen", temperature: 0.2]
        )

      assert :ok = Provider.run(prepared, hijack, fn _ -> :ok end)
      assert_receive {:relay_request, "Bearer relay-key", "qwen"}

      # The scout's budget is asked of the provider: unpriced on the route,
      # priced on the direct model beside it.
      refute Delegation.priced?(prepared, "relay:qwen")
      assert Delegation.priced?(prepared, "openai:gpt-4o-mini")
    end

    # The host readies the start model's route and no other, so a route the
    # person switches to answers from the state it has: the contract
    # `Lemieux.Provider.Route.ready/1` documents, seen from a session.
    test "a route that is not the start model's answers /provider unreadied", %{tmp_dir: dir} do
      runtime = :"lemieux_mux_route_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})

      mux =
        ProviderMux.new(
          [{"relay", relay(default: "relay:qwen")}],
          ReqLLM.new(api_keys: %{"openai" => "test-key"})
        )

      {:ok, session} =
        Lemieux.start_session(
          supervisor: runtime,
          store: JSONL.new(dir),
          provider: mux,
          model: "openai:gpt-4o-mini",
          tools: [],
          subscriber: self()
        )

      assert "relay" in Session.available_providers(session)
      assert Session.available_models(session, "relay") == ["relay:qwen", "relay:glm"]
      assert {:ok, "relay:qwen"} = Session.set_provider(session, "relay")
      assert {:ok, "relay:glm"} = Session.set_model(session, "relay:glm")
      assert {:error, {:unknown_model, "relay:nope"}} = Session.set_model(session, "relay:nope")
      refute_received {:route_ready, "relay"}
    end

    # A route lists models under its own name; one that listed another
    # provider's specification would make it mean two destinations.
    test "a route's catalogue is read under its own name only" do
      defmodule Leaky do
        @behaviour Lemieux.Provider.Route
        def available_models(_state, _opts), do: ["relay:a", "openai:gpt-5", "ixway:x"]
        def model_metadata(_state), do: %{"relay:a" => %{}, "openai:gpt-5" => %{kind: "hijacked"}}
        def validate_model(_state, _spec, _tools), do: :ok
        def context_window(_state, _spec), do: nil
        def reasoning_efforts(_state, _spec), do: []
        def target(_state, _request, _options), do: {:error, :never}
      end

      mux =
        ProviderMux.new([{"relay", ReqLLM.new(route: {Leaky, %{}})}], ReqLLM.new(api_keys: %{}))

      assert Provider.available_models(mux, provider: "relay") == ["relay:a"]
      assert Provider.available_models(mux, provider: "openai") == []
      assert Provider.available_models(mux) == ["relay:a"]
      assert Map.keys(Provider.model_metadata(mux)) == ["relay:a"]
    end

    test "ready/2 readies one route and discover/1 every route" do
      mux =
        ProviderMux.new(
          [{"relay", relay([])}, {"other", relay(name: "other")}],
          ReqLLM.new(api_keys: %{})
        )

      assert {:ok, mux} = ProviderMux.ready(mux, "other")
      assert_received {:route_ready, "other"}
      refute_received {:route_ready, "relay"}
      assert {:ok, ^mux} = ProviderMux.ready(mux, "openai")
      assert {:ok, ^mux} = ProviderMux.ready(mux, nil)

      assert {:ok, _mux} = ProviderMux.discover(mux)
      assert_received {:route_ready, "relay"}
      assert_received {:route_ready, "other"}

      failing = relay(ready: {:error, :down})

      assert {:error, :down} =
               ProviderMux.discover(ProviderMux.new([{"relay", failing}], ReqLLM.new()))
    end

    test "a default the route does not own, or none, is refused on preparation" do
      direct = ReqLLM.new(api_keys: %{})

      assert {:error, {:default_model_outside_route, "relay", "openai:gpt-5"}} =
               ProviderMux.prepare(
                 ProviderMux.new([{"relay", relay(default: "openai:gpt-5")}], direct),
                 "relay:@default"
               )

      assert {:error, {:no_default, "relay"}} =
               ProviderMux.prepare(
                 ProviderMux.new([{"relay", relay([])}], direct),
                 "relay:@default"
               )
    end

    test "ixway: with no such route is unavailable rather than handed to the direct connection" do
      mux = ProviderMux.new([], ReqLLM.new(api_keys: %{"openai" => "k"}))
      assert ProviderMux.route_names(mux) == []
      assert {:error, {:provider_unavailable, "ixway"}} = ProviderMux.prepare(mux, "ixway:x")

      assert {:error, {:provider_unavailable, "ixway"}} =
               Provider.validate_model(mux, "ixway:x", [])

      assert {:ok, ^mux, "openai:gpt-4o-mini"} = ProviderMux.prepare(mux, "openai:gpt-4o-mini")
    end
  end

  defp ixway_provider do
    connection =
      Ixway.new(endpoint: "https://gateway.example", api_key: "gateway-key")

    Ixway.provider(%{
      connection
      | models: [
          %{
            "id" => "team/coding",
            "ixway_ingress_dialects" => ["openai_chat"],
            "ixway_default_for" => ["openai_chat"],
            "max_input_tokens" => 32_000
          }
        ],
        client_policy: %{"default_profile" => %{"id" => "team/coding", "status" => "available"}}
    })
  end
end
