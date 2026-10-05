defmodule Lemieux.CLI.ConfigEnvironmentTest do
  use ExUnit.Case, async: false

  alias Lemieux.Benchmark.Judging
  alias Lemieux.CLI.Ollama
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Provider
  alias Lemieux.Request
  alias LemieuxTest.HTTPFixture

  @moduletag :tmp_dir
  @variables ~w(LMX_CONFIG LMX_MODEL LMX_ROUTER LMX_IXWAY_URL LMX_BASE_URL IXWAY_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY ZAI_API_KEY OLLAMA_API_KEY)

  setup do
    original = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables -- ["LMX_CONFIG"], &System.delete_env/1)
    app_key = Application.get_env(:req_llm, :openai_api_key)
    Application.delete_env(:req_llm, :openai_api_key)

    on_exit(fn ->
      Enum.each(original, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)

      if app_key,
        do: Application.put_env(:req_llm, :openai_api_key, app_key),
        else: Application.delete_env(:req_llm, :openai_api_key)
    end)

    :ok
  end

  test "environment overrides file settings and flags override the environment", %{tmp_dir: dir} do
    path =
      config(dir, %{
        "model" => "openai:gpt-4o-mini",
        "ixway" => %{
          "enabled" => true,
          "endpoint" => "http://localhost:4003",
          "api_key" => "file-key",
          "model" => "ixway:file-model"
        }
      })

    System.put_env("LMX_CONFIG", path)
    assert Options.inference_default(Judging.default_model()) == "ixway:file-model"
    System.put_env("LMX_IXWAY_URL", "https://env.example")
    System.put_env("IXWAY_API_KEY", "env-key")
    System.put_env("LMX_MODEL", "ixway:env-model")
    assert {:ok, options} = Options.parse([])
    assert options.ixway == "https://env.example"
    assert options.model == "ixway:env-model"
    assert Lemieux.Ixway.connection(Runtime.provider(options)).api_key == "env-key"

    assert {:ok, %{ixway: "https://flag.example", model: "ixway:flag-model"}} =
             Options.parse(["--ixway", "https://flag.example", "--model", "ixway:flag-model"])

    assert {:ok, %{ixway: nil}} = Options.parse(["--router", "direct"])
    assert {:ok, %{ixway: nil}} = Options.parse(["--base-url", "https://direct.example/v1"])
  end

  test "disabled Ixway is saved without becoming active and config none skips it", %{tmp_dir: dir} do
    path =
      config(dir, %{
        "model" => "openai:gpt-4o-mini",
        "ixway" => %{
          "enabled" => false,
          "endpoint" => "http://localhost:4003",
          "api_key" => "file-key",
          "model" => "ixway:file-model"
        }
      })

    System.put_env("LMX_CONFIG", path)
    assert {:ok, %{ixway: nil, model: "openai:gpt-4o-mini"}} = Options.parse([])
    assert {:ok, %{ixway: "http://localhost:4003"}} = Options.parse(["--router", "ixway"])
    assert {:ok, %{ixway: nil, model: model}} = Options.parse(["--config", "none"])
    assert model == Options.default_model()
  end

  test "direct requests use saved provider keys only when ambient keys are absent", %{
    tmp_dir: dir
  } do
    for {ambient, expected} <- [{nil, "file-key"}, {"env-key", "env-key"}] do
      if ambient,
        do: System.put_env("OPENAI_API_KEY", ambient),
        else: System.delete_env("OPENAI_API_KEY")

      parent = self()

      {endpoint, listener, server} =
        HTTPFixture.server(fn headers, _body, _socket ->
          send(parent, {:authorization, headers["authorization"]})

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

      path =
        config(dir, %{
          "model" => "openai:gpt-4o-mini",
          "base_url" => endpoint <> "/v1",
          "providers" => %{"openai" => %{"api_key" => "file-key"}}
        })

      assert {:ok, options} = Options.parse(["--config", path])
      provider = Runtime.provider(options)
      assert :ok = Provider.run(provider, Request.new(options.model), fn _ -> :ok end)
      assert_receive {:authorization, authorization}
      assert authorization == "Bearer " <> expected
      assert Provider.validate_model(provider, "ollama:local-model", []) == :ok
    end
  end

  test "an empty ambient key disables a saved credential", %{tmp_dir: dir} do
    System.put_env("OPENAI_API_KEY", "")
    path = config(dir, %{"providers" => %{"openai" => %{"api_key" => "file-key"}}})
    assert {:ok, options} = Options.parse(["--config", path])

    provider = Runtime.provider(options)

    assert {:error, {:missing_api_key, :openai, _}} =
             Provider.validate_model(provider, "openai:gpt-4o-mini", [])

    assert Provider.available_models(provider, scope: :openai) == []
  end

  test "the TUI includes saved Ixway and direct credentials in one session", %{tmp_dir: dir} do
    path =
      config(dir, %{
        "providers" => %{"openai" => %{"api_key" => "direct-key"}},
        "ixway" => %{
          "enabled" => true,
          "endpoint" => "https://gateway.example",
          "api_key" => "gateway-key"
        }
      })

    assert {:ok, options} =
             Options.parse(["--config", path, "--model", "openai:gpt-4o-mini"])

    provider = Runtime.tui_provider(options)
    assert {Lemieux.CLI.ProviderMux, _state} = provider
    assert {:ok, prepared} = Runtime.prepare(options, provider: provider, tools: [])
    assert prepared.model == "openai:gpt-4o-mini"

    assert "openai:gpt-4o-mini" in Provider.available_models(prepared.options[:provider],
             scope: :openai
           )

    refute inspect(prepared.options[:provider]) =~ "direct-key"
    refute inspect(prepared.options[:provider]) =~ "gateway-key"

    assert {:ok, direct} = Options.parse(["--config", path, "--router", "direct"])
    direct_provider = Runtime.tui_provider(direct)
    assert "openai:gpt-4o-mini" in Provider.available_models(direct_provider, scope: :openai)
    assert Provider.available_models(direct_provider, scope: :ixway) == []
  end

  test "a saved Coding Plan key does not advertise other routes sharing ZAI_API_KEY", %{
    tmp_dir: dir
  } do
    System.put_env("ZAI_API_KEY", "ambient-zai-key")
    System.put_env("ANTHROPIC_API_KEY", "independent-key")

    path =
      config(dir, %{
        "providers" => %{"zai_coding_plan" => %{"api_key" => "coding-plan-key"}},
        "ixway" => %{
          "enabled" => true,
          "endpoint" => "https://gateway.example",
          "api_key" => "gateway-key"
        }
      })

    assert {:ok, options} =
             Options.parse(["--config", path, "--model", "zai_coding_plan:glm-5.3"])

    provider = Runtime.tui_provider(options)

    assert "zai_coding_plan:glm-5.3" in Provider.available_models(provider,
             scope: :zai_coding_plan
           )

    assert Provider.available_models(provider, scope: :zai) == []
    assert Provider.available_models(provider, scope: :zai_coder) == []
    assert Provider.available_models(provider, scope: :anthropic) != []

    assert {:error, {:provider_unavailable, "zai_coder"}} =
             Provider.validate_model(provider, "zai_coder:glm-4.5", [])

    assert {:error, {:provider_unavailable, "zai"}} =
             Provider.run(provider, Request.new("zai:glm-4.5"), fn _ -> :ok end)

    assert {:ok, direct_options} = Options.parse(["--config", path, "--router", "direct"])
    direct_provider = Runtime.tui_provider(direct_options)
    assert Provider.available_models(direct_provider, scope: :zai_coder) == []
    assert Provider.available_models(direct_provider, scope: :anthropic) != []

    explicit =
      config(dir, %{
        "providers" => %{
          "zai_coding_plan" => %{"api_key" => "coding-plan-key"},
          "zai_coder" => %{"api_key" => "coder-key"}
        }
      })

    assert {:ok, both_options} = Options.parse(["--config", explicit])
    both = Runtime.tui_provider(both_options)
    assert Provider.available_models(both, scope: :zai_coder) != []
    assert Provider.available_models(both, scope: :zai) == []
  end

  test "an empty Ollama key prevents cloud discovery from using a saved key", %{tmp_dir: dir} do
    System.put_env("OLLAMA_API_KEY", "")
    path = config(dir, %{"providers" => %{"ollama_cloud" => %{"api_key" => "file-key"}}})
    assert {:ok, options} = Options.parse(["--config", path])

    assert Ollama.models(options,
             get: fn url, _opts ->
               refute url =~ "ollama.com"
               {:error, :offline}
             end
           ) == []
  end

  defp config(dir, data) do
    path = Path.join(dir, "config.json")
    File.write!(path, JSON.encode!(data))
    File.chmod!(path, 0o600)
    path
  end
end
