defmodule Lemieux.RelayExampleTest do
  @moduledoc """
  The route extension in `examples/extensions/relay`, loaded the way `lmx`
  loads it and run against a local server standing in for the one it relays
  to. The example has no Mix project of its own, so this suite is where it is
  checked: registration, selection by name and by `--router`, dispatch to the
  relay's endpoint with the relay's key and nothing else, the refusals, and
  what the transcript and the explanation record.
  """

  # `RELAY_API_KEY` is read from the process environment, which every test
  # shares, so this suite runs alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Lemieux.CLI.Extensions, as: CLIExtensions
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Routes
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias Lemieux.Store.JSONL
  alias LemieuxTest.HTTPFixture

  @example Path.expand("../../examples/extensions/relay", __DIR__)
  @key "relay-secret-token"
  @sse ~s|data: {"choices":[{"index":0,"delta":{"content":"relayed"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n|

  @moduletag :tmp_dir

  setup do
    previous = System.get_env("RELAY_API_KEY")
    System.put_env("RELAY_API_KEY", @key)

    on_exit(fn ->
      if previous,
        do: System.put_env("RELAY_API_KEY", previous),
        else: System.delete_env("RELAY_API_KEY")
    end)

    :ok
  end

  test "the script loads as a route source, and the host registers its route" do
    assert {:ok, %{spec: nil, routes: {LemieuxRelayExample, [config: config]}} = loaded} =
             CLIExtensions.load(@example)

    assert config["endpoint"] == "http://localhost:8000"
    assert loaded.provenance["routes"] == true

    {:ok, options} = Options.parse(["--config", "none"])
    assert {:ok, routes} = Routes.register(options, [loaded])
    assert Routes.names(routes) == ["relay"]

    {:ok, provider} = Routes.fetch(routes, "relay")
    assert Provider.available_models(provider) == ["relay:qwen3-32b"]
    assert Provider.available_models(provider, provider: "openai") == []
    assert Provider.context_window(provider, "relay:qwen3-32b") == 32_768
    assert Provider.estimate_cost(provider, Lemieux.Request.new("relay:qwen3-32b")) == nil
    assert {:ok, ^provider, "relay:qwen3-32b"} = Adapter.prepare(provider, "relay:@default")

    # The script's modules exist only once it is compiled, so they are named
    # as atoms here rather than as structs the test file would be checked against.
    assert {:error, %{__struct__: LemieuxRelayExample.Route.Error, __exception__: true} = error} =
             Provider.validate_model(provider, "relay:other", [])

    assert Exception.message(error) =~ "relay:other is not a model the relay serves"
    # The key is in no state at all: the route holds the variable's name and
    # reads it per request, so even the route's own struct shows nothing.
    {_module, state} = Adapter.route(provider)
    refute inspect(state) =~ @key
    assert inspect(state) =~ "RELAY_API_KEY"
  end

  test "a missing key, a bad endpoint and an unknown default are sentences, not a silent start" do
    System.delete_env("RELAY_API_KEY")
    {:ok, %{routes: {example, _opts}} = loaded} = CLIExtensions.load(@example)
    {:ok, options} = Options.parse(["--config", "none"])

    assert {:error, message} = Routes.register(options, [loaded])
    assert message =~ "extension relay (LemieuxRelayExample) could not build its routes"
    assert message =~ "RELAY_API_KEY"
    assert message =~ "RELAY_API_KEY=none"

    for {config, expected} <- [
          {%{"endpoint" => "localhost:8000/v1", "models" => ["a"]}, "http(s) origin"},
          {%{"models" => ["a"]}, "needs an \"endpoint\""},
          {%{"endpoint" => "http://localhost:8000"}, "needs \"models\""},
          {%{"endpoint" => "http://localhost:8000", "models" => ["a"], "default" => "b"},
           "must be one of its"}
        ] do
      assert {:error, message} = example.routes(config: config)
      assert message =~ expected, "#{inspect(config)}: #{message}"
    end
  end

  test "lmx run sends a relay model to the relay with the relay's key, and never elsewhere",
       %{tmp_dir: dir} do
    parent = self()

    {endpoint, listener, server} =
      HTTPFixture.server(
        fn path, headers, body, _socket ->
          send(parent, {:relayed, path, headers["authorization"], JSON.decode!(body)["model"]})
          %{status: 200, headers: [{"content-type", "text/event-stream"}], body: @sse}
        end,
        requests: 2
      )

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    config = config(dir, endpoint)

    # By model: `relay:@default` resolves to the configured default before
    # the session records its model, and the answer comes back from the relay.
    argv = [
      "run",
      "--config",
      config,
      "--model",
      "relay:@default",
      "--no-delegate",
      "--extension-dir",
      @example,
      "Ok?"
    ]

    {status, stdout, stderr} = run_lmx(argv, dir)
    assert status == :ok, stderr
    assert stdout =~ "relayed"
    assert_receive {:relayed, "/v1/chat/completions", "Bearer " <> @key, "qwen3-32b"}

    # By router: the route is the sole connection, as `--ixway` has always been.
    argv = [
      "run",
      "--config",
      config,
      "--router",
      "relay",
      "--no-delegate",
      "--extension-dir",
      @example,
      "Again?"
    ]

    {status, stdout, stderr} = run_lmx(argv, dir)
    assert status == :ok, stderr
    assert stdout =~ "relayed"
    assert_receive {:relayed, "/v1/chat/completions", "Bearer " <> @key, "qwen3-32b"}

    # The key went to the relay and nowhere else: not into the transcripts,
    # not into the provenance the harness snapshot records.
    for file <- Path.wildcard(Path.join([dir, "sessions", "**", "*.jsonl"])) do
      refute File.read!(file) =~ @key, "#{file} holds the relay key"
    end

    transcripts = Path.wildcard(Path.join([dir, "sessions", "**", "*.jsonl"]))
    assert transcripts != []

    # Resuming one of them without the extension refuses before a session
    # exists, and says what brings the route back; it used to start, append
    # the prompt and fail the first request as an unknown provider.
    id = transcripts |> hd() |> Path.basename(".jsonl")
    before = File.read!(hd(transcripts))

    {status, _stdout, stderr} =
      run_lmx(["run", "--config", config, "--resume", id, "Again?"], dir)

    assert {:error, _status} = status
    assert stderr =~ "relay:qwen3-32b names relay, which is not a provider lmx knows"
    assert stderr =~ "--extension-dir PATH"
    assert File.read!(hd(transcripts)) == before
  end

  test "a model the relay does not serve, and a route nobody registered, are refused", %{
    tmp_dir: dir
  } do
    config = config(dir, "http://127.0.0.1:9")

    argv = [
      "run",
      "--config",
      config,
      "--model",
      "relay:other",
      "--no-delegate",
      "--extension-dir",
      @example,
      "Ok?"
    ]

    {status, _stdout, stderr} = run_lmx(argv, dir)
    assert {:error, _status} = status
    assert stderr =~ "relay:other is not a model the relay serves"

    # Under `--router relay` the relay is the sole connection: a direct model
    # is refused by the route, never sent to the direct provider.
    argv = [
      "run",
      "--config",
      config,
      "--router",
      "relay",
      "--model",
      "openai:gpt-5",
      "--no-delegate",
      "--extension-dir",
      @example,
      "Ok?"
    ]

    {status, _stdout, stderr} = run_lmx(argv, dir)
    assert {:error, _status} = status
    assert stderr =~ "openai:gpt-5 is not a model the relay serves"

    # Without the extension there is no `relay` route: the model is a
    # provider lmx does not know, and `--router relay` says what registers one.
    {status, _stdout, stderr} =
      run_lmx(["run", "--config", config, "--model", "relay:qwen3-32b", "Ok?"], dir)

    assert {:error, 2} = status
    assert stderr =~ "names a provider lmx does not know (relay)"

    {status, _stdout, stderr} =
      run_lmx(["run", "--config", config, "--router", "relay", "Ok?"], dir)

    assert {:error, 2} = status
    assert stderr =~ "no model route named relay is registered"
    assert stderr =~ "routes/1"
  end

  test "lmx explain reports the route, a route-managed credential and the extension as loaded only",
       %{tmp_dir: dir} do
    config = config(dir, "http://127.0.0.1:9")

    argv = [
      "explain",
      "--config",
      config,
      "--model",
      "relay:@default",
      "--extension-dir",
      @example
    ]

    {status, stdout, stderr} = run_lmx(argv, dir)
    assert status == :ok, stderr

    report = JSON.decode!(stdout)
    assert report["diagnostics"]["model"] == "relay:qwen3-32b"
    assert report["diagnostics"]["route"] == "relay"

    assert report["diagnostics"]["credentials"] == %{
             "status" => "route_managed",
             "route" => "relay",
             "module" => "LemieuxRelayExample.Route"
           }

    # Applied extensions shape the harness; this one only offers a route.
    refute Enum.any?(report["extensions"], &(&1["module"] == "LemieuxRelayExample"))
    refute stdout =~ @key
  end

  # A private config file pointing the relay at the test's server: the
  # person's `extension_options` over the manifest's `options`.
  defp config(dir, endpoint) do
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "extension_options" => %{"relay" => %{"endpoint" => endpoint}}
      })
    )

    File.chmod!(path, 0o600)
    path
  end

  defp run_lmx(argv, dir) do
    opts = [
      store: JSONL.new(Path.join(dir, "sessions")),
      supervisor: :"relay_example_#{System.unique_integer([:positive])}",
      cwd: dir,
      stdin_terminal?: true,
      terminal?: false
    ]

    test = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(test, {:status, Lemieux.CLI.run(argv, opts)}) end)
        send(test, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end
end
