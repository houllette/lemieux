defmodule Lemieux.CLI.OptionsTest do
  # Not async: these read the OS environment, and the tests that pin a value
  # in it would leak into anything else reading the same variable.
  use ExUnit.Case, async: false

  alias Lemieux.Benchmark.Judging
  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime

  defp with_env(name, value, fun) do
    original = System.get_env(name)

    if value, do: System.put_env(name, value), else: System.delete_env(name)

    try do
      fun.()
    after
      if original, do: System.put_env(name, original), else: System.delete_env(name)
    end
  end

  defp with_envs(pairs, fun) do
    pairs
    |> Enum.reduce(fun, fn {name, value}, inner -> fn -> with_env(name, value, inner) end end)
    |> then(& &1.())
  end

  describe "--ixway" do
    test "opts in explicitly, selecting the authenticated default with only a gateway key" do
      with_env("LMX_MODEL", nil, fn ->
        with_env("LMX_BASE_URL", nil, fn ->
          assert {:ok, options} = Options.parse(["--ixway", "https://gateway.example"])
          assert options.ixway == "https://gateway.example"
          assert options.model == "ixway:@default"
          assert {Lemieux.Providers.ReqLLM, state} = provider = Runtime.provider(options)
          assert Lemieux.Ixway.connection(provider).endpoint == "https://gateway.example"
          refute Keyword.has_key?(state.options, :transport_routes)
        end)
      end)
    end

    test "the environment opts in and a flag overrides its endpoint" do
      with_env("LMX_BASE_URL", nil, fn ->
        with_env("LMX_IXWAY_URL", "https://shell.example", fn ->
          assert {:ok, %{ixway: "https://shell.example"}} = Options.parse([])

          assert {:ok, %{ixway: "https://flag.example"}} =
                   Options.parse(["--ixway", "https://flag.example"])

          assert {Lemieux.Providers.ReqLLM, _state} = provider = Runtime.provider()
          assert Lemieux.Ixway.connection(provider).endpoint == "https://shell.example"
          assert Options.inference_default(Judging.default_model()) == "ixway:@default"
        end)
      end)
    end

    test "rejects mixed gateways and preserves an explicit model choice" do
      assert {:error, reason} =
               Options.parse([
                 "--ixway",
                 "https://gateway.example",
                 "--base-url",
                 "https://other.example"
               ])

      assert reason =~ "cannot be combined"

      assert {:ok, %{model: "ixway:team/coding"}} =
               Options.parse([
                 "--ixway",
                 "https://gateway.example",
                 "--model",
                 "ixway:team/coding"
               ])

      assert {:error, _} = Options.parse(["--ixway", "https://gateway.example/v1"])
    end
  end

  describe "--base-url" do
    test "is absent when model calls should go directly to their provider" do
      with_env("LMX_BASE_URL", nil, fn ->
        assert {:ok, %{base_url: nil}} = Options.parse([])
      end)
    end

    test "can route a whole shell through an API gateway" do
      with_env("LMX_BASE_URL", "https://gateway.example/llm", fn ->
        assert {:ok, %{base_url: "https://gateway.example/llm"}} = Options.parse([])
      end)
    end

    test "a flag beats the environment" do
      with_env("LMX_BASE_URL", "https://shell.example", fn ->
        assert {:ok, %{base_url: "http://127.0.0.1:4000"}} =
                 Options.parse(["--base-url", "http://127.0.0.1:4000"])
      end)
    end

    test "rejects a value that is not an HTTP URL before starting a session" do
      assert {:error, reason} = Options.parse(["--base-url", "gateway.example"])
      assert reason =~ "absolute http:// or https:// URL"
    end
  end

  describe "parse/1" do
    test "defaults new sessions to the first recommended model, not one vendor's legacy default" do
      assert {:ok, options} = Options.parse(["hello"])
      assert options.model == "anthropic:claude-sonnet-5"
      assert options.model == Options.default_model()
      assert options.model == hd(Models.recommended()).model
      assert options.argv == ["hello"]
    end

    test "the environment sets a model for a whole shell" do
      with_env("LMX_MODEL", "openai:gpt-5", fn ->
        assert {:ok, %{model: "openai:gpt-5"}} = Options.parse(["hi"])
      end)
    end

    test "a flag beats the environment" do
      with_env("LMX_MODEL", "openai:gpt-5", fn ->
        assert {:ok, %{model: "anthropic:claude-opus-5"}} =
                 Options.parse(["--model", "anthropic:claude-opus-5", "hi"])
      end)
    end

    # Reported from a real session: uncaptured, the terminal translates the
    # wheel into arrow keys, which the input box reads as history navigation,
    # so the wheel did something actively wrong. Capturing it costs the
    # terminal's drag selection, which is why there is a way back.
    test "the wheel scrolls the transcript unless the mouse is handed back" do
      assert {:ok, %{host: %{mouse: true}}} = Options.parse(["hi"])
      assert {:ok, %{host: %{mouse: false}}} = Options.parse(["--no-mouse", "hi"])
      assert {:ok, %{host: %{mouse: true}}} = Options.parse(["--mouse", "hi"])
    end

    test "keeps the arguments that are not options" do
      assert {:ok, %{argv: ["two", "words"], system: "terse"}} =
               Options.parse(["--system", "terse", "two", "words"])
    end

    test "an unknown option is named rather than swallowed" do
      assert Options.parse(["--nope", "hi"]) == {:error, "unrecognised option --nope"}
    end

    test "--hooks names an explicit command-hook file" do
      assert {:ok, %{hooks_config: ".lmx/hooks.json"}} =
               Options.parse(["--hooks", ".lmx/hooks.json"])
    end

    test "extension paths and selections are repeatable" do
      assert {:ok, options} =
               Options.parse([
                 "--skill-dir",
                 "one",
                 "--skill-dir",
                 "two",
                 "--plugin-dir",
                 "local-plugin",
                 "--marketplace",
                 "team-one",
                 "--marketplace",
                 "team-two",
                 "--plugin",
                 "review@one",
                 "--plugin",
                 "deploy@two"
               ])

      assert options.skill_dirs == ["one", "two"]
      assert options.plugin_dirs == ["local-plugin"]
      assert options.marketplaces == ["team-one", "team-two"]
      assert options.plugins == ["review@one", "deploy@two"]
    end
  end

  describe "--context-window" do
    test "is absent by default, because the model database usually knows" do
      assert {:ok, %{context_window: nil}} = Options.parse([])
    end

    test "is how a locally served model gets one at all" do
      # Nothing published a datasheet for `ollama:qwen3.8:27b-mxfp8`, so
      # without this the session never compacts on a threshold.
      assert {:ok, %{context_window: 32_768}} = Options.parse(["--context-window", "32768"])
    end
  end

  describe "the OAuth options" do
    test "have defaults, so a server that wants authorization works without any of them" do
      assert {:ok, options} = Options.parse([])

      assert options.oauth_callback_port == 8642
      assert options.credentials =~ "credentials.json"
      assert options.oauth_clients == %{}
    end

    test "the callback port can be moved when something else has it" do
      assert {:ok, %{oauth_callback_port: 9000}} =
               Options.parse(["--oauth-callback-port", "9000"])
    end

    test "a hand-registered client id is keyed by the authorization server it belongs to" do
      argv = ["--oauth-client-id", "https://github.com/login/oauth=Iv1.abc"]

      assert {:ok, options} = Options.parse(argv)

      assert options.oauth_clients == %{
               "https://github.com/login/oauth" => %{"client_id" => "Iv1.abc"}
             }
    end

    test "more than one can be given, because one machine talks to more than one forge" do
      argv = [
        "--oauth-client-id",
        "https://one.example=a",
        "--oauth-client-id",
        "https://two.example=b"
      ]

      assert {:ok, options} = Options.parse(argv)
      assert map_size(options.oauth_clients) == 2
    end

    test "one written without an issuer is refused, with an example" do
      assert {:error, reason} = Options.parse(["--oauth-client-id", "Iv1.abc"])

      assert reason =~ "ISSUER=CLIENT_ID"
    end
  end

  # Three values, because "nothing said" and "said no" now lead somewhere
  # different: nothing said loads the repository's own `.mcp.json`.
  describe "--mcp-config and --project-mcp" do
    # The suite pins `LMX_PROJECT_MCP` off so command tests do not reach for
    # this checkout's own servers; these are the tests about the setting, so
    # they unpin it.
    defp parsed(argv),
      do: with_env("LMX_PROJECT_MCP", nil, fn -> Options.parse(argv) end)

    test "nothing said means the repository's own configuration is used" do
      assert {:ok, options} = parsed([])
      assert options.mcp_config == nil
    end

    test "a named file wins" do
      assert {:ok, options} = parsed(["--mcp-config", "/tmp/servers.json"])
      assert options.mcp_config == "/tmp/servers.json"
    end

    test "--no-project-mcp says no, which is not the same as saying nothing" do
      assert {:ok, options} = parsed(["--no-project-mcp"])
      assert options.mcp_config == false
    end

    test "a shell can say no for every command in it" do
      with_env("LMX_PROJECT_MCP", "0", fn ->
        assert {:ok, options} = Options.parse([])
        assert options.mcp_config == false
      end)

      # And the flag still beats it, which is the point of having both.
      with_env("LMX_PROJECT_MCP", "0", fn ->
        assert {:ok, options} = Options.parse(["--project-mcp"])
        assert options.mcp_config == nil
      end)
    end

    test "--project-mcp is the default said out loud" do
      assert {:ok, options} = parsed(["--project-mcp"])
      assert options.mcp_config == nil
    end

    test "a named file beats an opt-out, because naming one is asking for it" do
      assert {:ok, options} = parsed(["--no-project-mcp", "--mcp-config", "/tmp/servers.json"])
      assert options.mcp_config == "/tmp/servers.json"
    end

    test "what a host has been told to trust decides which warnings are left" do
      assert {:ok, default} = parsed([])
      assert Runtime.trusted(default) == []

      assert {:ok, hooked} = parsed(["--hooks", "/tmp/hooks.json"])
      assert Runtime.trusted(hooked) == [:hooks]
    end
  end

  describe "log_level/0" do
    test "defaults to error, so a library's warning stays out of a person's terminal" do
      assert Options.log_level() == :error
    end

    test "an unrecognised level falls back rather than failing the command" do
      with_env("LMX_LOG_LEVEL", "chatty", fn -> assert Options.log_level() == :error end)
    end

    test "is overridable for when the sentence on stderr is not enough" do
      with_env("LMX_LOG_LEVEL", "debug", fn -> assert Options.log_level() == :debug end)
    end
  end

  describe "which flags a command takes" do
    test "a flag for another command is named as such, not as unknown" do
      assert {:error, "--model does not apply to lmx log"} =
               Options.parse(["--model", "x:y"], command: :log)

      assert {:error, "--mouse does not apply to lmx run"} =
               Options.parse(["--mouse"], command: :run)

      assert {:ok, %{host: %{continue: true}}} = Options.parse(["-c"], command: :tui)
      assert {:ok, %{host: %{continue: true}}} = Options.parse(["-c"], command: :run)
    end

    test "a missing or mistyped value says so" do
      assert {:error, "missing value for --model"} = Options.parse(["--model"], command: :run)

      assert {:error, message} = Options.parse(["--context-window", "lots"], command: :run)
      assert message =~ "invalid value for --context-window"
      assert message =~ "integer"

      assert {:error, message} = Options.parse(["--modle", "x:y"], command: :run)
      assert message =~ "unrecognised option --modle"
      assert message =~ "--model"
    end
  end

  # Copying `.env.example` to `.env` used to leave `LMX_WEB_SEARCH=` in the
  # environment, a web-search backend called "", and every command refused
  # to start. An empty value is a template left unfilled, never a choice.
  describe "an empty variable is an unset one" do
    @routing ~w(LMX_WEB_SEARCH LMX_MODEL LMX_ROUTER LMX_BASE_URL LMX_IXWAY_URL)

    test "LMX_WEB_SEARCH, LMX_MODEL, LMX_ROUTER, LMX_BASE_URL and LMX_IXWAY_URL" do
      unset = Enum.map(@routing, &{&1, nil})
      assert {:ok, expected} = with_envs(unset, fn -> Options.parse(["hi"]) end)

      for name <- @routing do
        assert {:ok, options} =
                 with_envs([{name, ""} | List.keydelete(unset, name, 0)], fn ->
                   Options.parse(["hi"])
                 end),
               "an empty #{name} stopped lmx from starting"

        assert options.model == expected.model, name
        assert options.host.model_source == :fallback, name
        assert options.web_search == nil, name
        assert options.base_url == nil, name
        assert options.ixway == nil, name
      end

      with_envs(Enum.map(@routing, &{&1, ""}), fn ->
        assert {:ok, options} = Options.parse(["hi"])
        assert Options.automatic_web?(options)
        assert Options.inference_default("judge:model") == "judge:model"
      end)
    end

    test "a blank value is unset too, and the other named values fall back to their defaults" do
      assert Options.env("LMX_TEST_NEVER_SET_#{System.unique_integer([:positive])}") == nil

      with_env("LMX_MODEL", "  ", fn -> assert Options.env("LMX_MODEL") == nil end)

      blank = Enum.map(~w(LMX_SESSIONS_DIR LMX_CREDENTIALS LMX_OAUTH_CALLBACK_PORT), &{&1, ""})

      with_envs(blank, fn ->
        assert {:ok, options} = Options.parse(["hi"])
        assert options.sessions_dir == Path.expand("~/.lmx/sessions")
        # The default store, whichever module names it; a blank variable was
        # the empty path, which is the working directory.
        assert Path.type(options.credentials) == :absolute
        assert options.credentials == Options.default_credentials()
        assert options.oauth_callback_port == 8642
      end)
    end

    test "the switches whose empty value means off keep that meaning" do
      with_env("LMX_WEB_FETCH", "", fn ->
        assert {:ok, %{web_fetch: false}} = Options.parse(["--web-search", "brave", "hi"])
      end)
    end
  end

  describe "personal state" do
    # In ExUnit's tmp_dir: a directory of its own under the system's temporary
    # one was left there by every run.
    @tag :tmp_dir
    test "--config none has none; a config file puts it beside the file", %{tmp_dir: dir} do
      assert {:ok, %{host: %{state_dir: nil, model_source: :fallback}}} =
               Options.parse(["--config", "none"])

      path = Path.join(dir, "config.json")
      File.write!(path, ~s({"version":1,"model":"test:configured"}))
      File.chmod!(path, 0o600)

      assert {:ok, %{host: %{state_dir: ^dir, model_source: :config}}} =
               Options.parse(["--config", path])

      assert {:ok, %{host: %{model_source: :flag}}} =
               Options.parse(["--config", path, "--model", "test:typed"])

      with_env("LMX_HOME", dir, fn ->
        assert {:ok, %{host: %{state_dir: ^dir}}} = Options.parse(["--config", "none"])
      end)
    end
  end
end
