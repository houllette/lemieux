defmodule Lemieux.Provider.RouteTest do
  use ExUnit.Case, async: true

  alias Lemieux.Provider
  alias Lemieux.Provider.Route
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias Lemieux.Request

  # The smallest route that can answer every required question. It refuses
  # every request at `target/3`, which is enough to show the adapter took its
  # wire target from the route rather than from req_llm's catalog.
  defmodule Gateway do
    @behaviour Route

    @impl Route
    def available_models(%{models: models}, _opts), do: models

    @impl Route
    def validate_model(%{models: models}, spec, _tools) do
      if spec in models, do: :ok, else: {:error, {:gateway, :unknown, spec}}
    end

    @impl Route
    def context_window(%{window: window}, _spec), do: window

    @impl Route
    def reasoning_efforts(_state, _spec), do: ["low", "high"]

    @impl Route
    def target(%{owner: owner}, request, options) do
      send(owner, {:target, request.model, options})
      {:error, {:gateway, :refused}}
    end
  end

  defp gateway(overrides \\ %{}) do
    {Gateway, Map.merge(%{models: ["gw:a"], window: 4_096, owner: self()}, overrides)}
  end

  test "an adapter built on a route asks the route, not req_llm's catalog" do
    provider = Adapter.new(route: gateway())

    assert Provider.available_models(provider) == ["gw:a"]
    assert Provider.validate_model(provider, "gw:a", []) == :ok
    assert {:error, {:gateway, :unknown, "gw:b"}} = Provider.validate_model(provider, "gw:b", [])
    assert Provider.context_window(provider, "gw:a") == 4_096

    # The route's menu, with the adapter's own "leave it to the route"
    # sentinel in front: that sentinel is the adapter's, not the gateway's.
    assert Provider.reasoning_efforts(provider, "gw:a") == ["default", "low", "high"]

    # A route that does not price requests leaves the estimate unknown, which
    # a cost cap treats as a refusal rather than as free.
    assert Provider.estimate_cost(provider, Request.new("gw:a")) == nil
  end

  test "run/3 takes its wire target from the route and returns the route's refusal" do
    provider = Adapter.new(route: gateway(), max_tokens: 5)
    request = Request.new("gw:a", params: [temperature: 0.1])

    assert {:error, {:gateway, :refused}} =
             Provider.run(provider, request, fn event -> flunk("emitted #{inspect(event)}") end)

    # Provider options and the request's own parameters both reach the route,
    # which decides what may cross to the wire.
    assert_receive {:target, "gw:a", options}
    assert options[:max_tokens] == 5
    assert options[:temperature] == 0.1
  end

  test "a route excludes direct-provider credentials and routing" do
    for conflicting <- [
          [api_key: "k"],
          [api_keys: %{"openai" => "k"}],
          [api_key_defaults: %{"openai" => "k"}],
          [base_url: "https://direct.example"],
          [transport_routes: %{}]
        ] do
      assert_raise ArgumentError, ~r/:route cannot be combined/, fn ->
        Adapter.new([route: gateway()] ++ conflicting)
      end
    end

    assert_raise ArgumentError, ~r/:route must be/, fn -> Adapter.new(route: :nope) end
  end

  # Unknown options are forwarded to req_llm on every request, so an `:ixway`
  # that was quietly forwarded would build a direct provider with no key and
  # the gateway settings lost. It is refused instead, naming the replacement.
  test ":ixway is refused rather than forwarded" do
    assert_raise ArgumentError, ~r/Lemieux\.Ixway\.provider\/2/, fn ->
      Adapter.new(ixway: [endpoint: "https://gateway.example"])
    end
  end

  test "the optional hooks are identity without a route, and for a route that lacks them" do
    ref = make_ref()
    message = %{"role" => "assistant"}

    for route <- [nil, gateway()] do
      assert Route.observe_stream(route, :response, ref) == :response
      assert Route.finish_stream(route, {:ok, :result}, ref) == {:ok, :result}
      assert Route.after_stream(route, Lemieux.Request.new("test:model"), ref) == :ok
      assert Route.annotate_message(route, message, :result) == message
      assert Route.estimate_cost(route, Request.new("gw:a")) == nil
    end
  end

  # This is the cycle the route exists to break: an adapter that calls
  # `Lemieux.Ixway` and a gateway that calls the adapter recompile each other
  # on every edit. The import table lists every remote call the compiled
  # adapter makes; the gateway must not be in it.
  test "the adapter makes no call into the gateway it once named" do
    # The beam on disk, not `:code.which/1`: under `mix test --cover` that
    # answers `:cover_compiled`, and the nightly coverage job failed here.
    beam = :lemieux |> Application.app_dir("ebin/#{Adapter}.beam") |> String.to_charlist()
    {:ok, {Adapter, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])

    called = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    refute Lemieux.Ixway in called
    assert Route in called
  end
end
