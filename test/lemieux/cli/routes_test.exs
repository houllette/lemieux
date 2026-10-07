defmodule Lemieux.CLI.RoutesTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.ProviderMux
  alias Lemieux.CLI.Routes
  alias Lemieux.CLI.Runtime
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias LemieuxTest.StaticRoute

  # What a loaded extension's `routes/1` may hand the host: routes built from
  # its options, a refusal, or something that is neither.
  defmodule Offers do
    @behaviour Lemieux.Extension.Routes

    @impl true
    def routes(config: %{"error" => message}), do: {:error, message}
    def routes(config: %{"raise" => true}), do: {:error, %RuntimeError{message: "no key"}}
    def routes(config: %{"garbage" => true}), do: :nope

    def routes(config: %{"names" => names} = config) do
      {:ok,
       Enum.map(names, fn name ->
         %{
           name: name,
           route:
             {StaticRoute,
              StaticRoute.new(
                name: name,
                models: ["a"],
                default: "#{name}:a",
                owner: config["owner"]
              )}
         }
       end)}
    end

    def routes(config: %{"bad" => shape}), do: {:ok, [shape]}
  end

  defp loaded(name, config, module \\ Offers) do
    %{
      spec: nil,
      routes: {module, [config: config]},
      provenance: %{"name" => name, "module" => inspect(module), "routes" => true}
    }
  end

  defp harness_only(name) do
    %{spec: {Lemieux.Extensions.Search, []}, routes: nil, provenance: %{"name" => name}}
  end

  defp options(argv \\ []) do
    {:ok, options} = Options.parse(["--config", "none" | argv])
    options
  end

  describe "register/2" do
    test "Ixway first when configured, then each extension's routes in loading order" do
      options = options(["--ixway", "https://gateway.example"])

      assert {:ok, routes} =
               Routes.register(options, [
                 harness_only("audit"),
                 loaded("relay", %{"names" => ["relay", "other"]}),
                 loaded("more", %{"names" => ["third"]})
               ])

      assert Routes.names(routes) == ["ixway", "relay", "other", "third"]
      assert Routes.registered?(routes, "relay")
      refute Routes.registered?(routes, "openai")
      refute Routes.registered?(routes, nil)

      # Each is the host's adapter around the extension's route, so inference
      # still goes through req_llm with this host's timeouts.
      assert {:ok, {Adapter, _state} = provider} = Routes.fetch(routes, "relay")
      assert {StaticRoute, %StaticRoute{name: "relay"}} = Adapter.route(provider)
      assert Provider.available_models(provider) == ["relay:a"]
      assert {:ok, {Adapter, _}} = Routes.fetch(routes, "ixway")
      assert Routes.fetch(routes, "nope") == :error
    end

    test "nothing configured and nothing offered registers nothing" do
      assert Routes.register(options(), [harness_only("audit")]) == {:ok, []}
      assert Routes.builtin(options()) == []
    end

    test "a name already taken, the gateway's name and a direct provider's name are refused" do
      ixway = options(["--ixway", "https://gateway.example"])

      assert {:error, message} = Routes.register(ixway, [loaded("mine", %{"names" => ["ixway"]})])
      assert message =~ "extension mine"
      assert message =~ "belongs to Lemieux.Ixway"

      assert {:error, message} =
               Routes.register(options(), [
                 loaded("first", %{"names" => ["relay"]}),
                 loaded("second", %{"names" => ["relay"]})
               ])

      assert message =~ "extension second"
      assert message =~ "extension first"
      assert message =~ "already registered"

      assert {:error, message} =
               Routes.register(options(), [loaded("mine", %{"names" => ["openai"]})])

      assert message =~ "shadow req_llm's openai provider"
    end

    test "a refusal, a malformed registration and a malformed return each name the extension" do
      assert {:error, message} =
               Routes.register(options(), [
                 loaded("relay", %{"error" => "RELAY_API_KEY is not set"})
               ])

      assert message ==
               "extension relay (Lemieux.CLI.RoutesTest.Offers) could not build its routes: RELAY_API_KEY is not set"

      assert {:error, message} = Routes.register(options(), [loaded("relay", %{"raise" => true})])
      assert message =~ "could not build its routes: no key"

      assert {:error, message} =
               Routes.register(options(), [
                 loaded("relay", %{"bad" => %{name: "Relay", route: {StaticRoute, %{}}}})
               ])

      assert message =~ "offers routes lmx cannot register"
      assert message =~ ~s(route name "Relay")

      assert {:error, message} =
               Routes.register(options(), [loaded("relay", %{"garbage" => true})])

      assert message =~ "routes/1 must return {:ok, [routes]} or {:error, reason}, got :nope"
    end
  end

  describe "selected/2" do
    test "--router naming no registered route is refused with what would register one" do
      options = options(["--router", "relay"])
      assert options.host.route == "relay"

      assert {:error, message} = Routes.selected(options, [])
      assert message =~ "no model route named relay is registered"
      assert message =~ "routes/1"
      assert message =~ "no loaded extension registers one"

      {:ok, routes} = Routes.register(options, [loaded("other", %{"names" => ["other"]})])
      assert {:error, message} = Routes.selected(options, routes)
      assert message =~ "registered: other"

      {:ok, routes} = Routes.register(options, [loaded("relay", %{"names" => ["relay"]})])
      assert Routes.selected(options, routes) == :ok
      assert Routes.selected(options(), []) == :ok
    end
  end

  describe "the runtime's providers" do
    setup do
      {:ok, routes} =
        Routes.register(options(), [loaded("relay", %{"names" => ["relay"], "owner" => self()})])

      %{routes: routes}
    end

    test "lmx run carries the routes beside the direct connection, or one route alone", %{
      routes: routes
    } do
      assert {ProviderMux, _} = mux = Runtime.provider(options(), routes)
      assert ProviderMux.route_names(mux) == ["relay"]
      assert Provider.available_models(mux, provider: "relay") == ["relay:a"]

      # `--router relay`: the route and nothing else, as `--ixway` has always been.
      assert {Adapter, _} = sole = Runtime.provider(options(["--router", "relay"]), routes)
      assert {StaticRoute, _} = Adapter.route(sole)
      assert Provider.available_models(sole, provider: "openai") == []

      # No route registered: the direct connection, as before.
      assert {Adapter, _} = direct = Runtime.provider(options(), [])
      assert Adapter.route(direct) == nil
      assert Runtime.provider(options()) == direct
    end

    test "the terminal UI readies the start model's route and no other", %{routes: _routes} do
      {:ok, routes} =
        Routes.register(options(), [
          loaded("relay", %{"names" => ["relay"], "owner" => self()}),
          loaded("other", %{"names" => ["other"], "owner" => self()})
        ])

      assert {ProviderMux, _} = tui = Runtime.tui_provider(options(), routes)

      assert {:ok, {ProviderMux, _} = readied} =
               Runtime.discover_tui_provider(tui, "relay:@default")

      assert_received {:route_ready, "relay"}
      refute_received {:route_ready, "other"}

      assert {:ok, ^readied} = Runtime.discover_tui_provider(readied, "openai:gpt-4o-mini")
      assert Runtime.tui_provider(options(), []) == Runtime.provider(options(), [])
      assert length(routes) == 2
    end

    test "with_routes/2 registers once and route?/2 reads the result", %{routes: _routes} do
      opts = [extensions_dir: System.tmp_dir!()]
      assert {:ok, opts} = Runtime.with_routes(options(), opts)
      assert Keyword.fetch!(opts, :routes) == []
      refute Runtime.route?(opts, "relay:a")

      # A host's own provider decides where requests go: nothing is registered.
      assert {:ok, [provider: :mine]} =
               Runtime.with_routes(options(["--router", "relay"]), provider: :mine)

      refute Runtime.route?([provider: :mine], "relay:a")

      assert {:error, message} = Runtime.with_routes(options(["--router", "relay"]), [])
      assert message =~ "no model route named relay"
    end
  end
end
