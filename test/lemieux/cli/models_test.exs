defmodule Lemieux.CLI.ModelsTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.State

  @moduletag :tmp_dir

  defp fallback(state_dir) do
    options = %Options{model: Options.default_model()}
    put_in(options.host.state_dir, state_dir)
  end

  defp chosen(options, model, source),
    do: put_in(%{options | model: model}.host.model_source, source)

  # A local daemon serving `tags` as `/api/tags` lists them, and describing
  # each through `/api/show` as `shows` says — by default, with the
  # capabilities its tag lists; a tag missing from `shows` is one the daemon
  # refuses to describe.
  defp ollama(tags), do: ollama(tags, Map.new(tags, &{&1["name"], shown(&1["capabilities"])}))

  defp ollama(tags, shows) do
    test = self()

    [
      ollama: [
        get: fn url, _opts ->
          assert String.ends_with?(url, "/api/tags")
          {:ok, %Req.Response{status: 200, body: %{"models" => tags}}}
        end,
        post: fn url, opts ->
          assert String.ends_with?(url, "/api/show")
          name = opts[:json]["model"]
          send(test, {:shown, name})

          case Map.fetch(shows, name) do
            {:ok, body} -> {:ok, %Req.Response{status: 200, body: body}}
            :error -> {:ok, %Req.Response{status: 404, body: %{"error" => "not found"}}}
          end
        end
      ]
    ]
  end

  defp no_daemon do
    [
      ollama: [
        get: fn _url, _opts -> {:error, %Req.TransportError{reason: :econnrefused}} end,
        post: fn _url, _opts -> flunk("nothing answered /api/tags, so nothing is described") end
      ]
    ]
  end

  defp tag(name, modified_at, capabilities \\ nil) do
    %{"name" => name, "modified_at" => modified_at, "details" => %{}}
    |> then(&if(capabilities, do: Map.put(&1, "capabilities", capabilities), else: &1))
  end

  defp shown(capabilities, context_length \\ nil) do
    info = if context_length, do: %{"llama.context_length" => context_length}, else: %{}
    %{"capabilities" => capabilities, "model_info" => info}
  end

  describe "the order of recommended/0" do
    # The launch decision: a keyless newcomer is steered to no vendor, and
    # when keys are what decides, the ones most people hold come first.
    test "Anthropic and OpenAI lead it, and the hermetic default is its first row" do
      assert [%{provider: "anthropic"}, %{provider: "openai"} | rest] = Models.recommended()
      assert "zai_coding_plan" in Enum.map(rest, & &1.provider)
      assert Options.default_model() == hd(Models.recommended()).model
    end

    test "every recommended model names its provider and key variable" do
      for row <- Models.recommended() do
        assert String.starts_with?(row.model, row.provider <> ":")
        assert is_binary(row.env) and row.env != ""
      end
    end
  end

  describe "resolve/2" do
    test "the last chosen model wins when its provider can still be reached", %{tmp_dir: dir} do
      :ok = State.remember_model(dir, "openai:gpt-6-sol")
      env = %{"OPENAI_API_KEY" => "set"}

      assert %{model: "openai:gpt-6-sol", host: %{model_source: :last_used}} =
               Models.resolve(fallback(dir), env: env)

      # A remembered model whose key is gone is not a model lmx can start on.
      assert %{model: model, host: %{model_source: source}} =
               Models.resolve(fallback(dir), env: %{})

      refute model == "openai:gpt-6-sol" and source == :last_used
    end

    test "otherwise the first provider with a key, in the documented order", %{tmp_dir: dir} do
      env = %{"ZAI_API_KEY" => "set", "OPENAI_API_KEY" => "set", "ANTHROPIC_API_KEY" => "set"}

      assert %{model: "anthropic:claude-sonnet-5", host: %{model_source: :credential}} =
               Models.resolve(fallback(dir), env: env)

      assert %{model: "openai:gpt-6-sol"} =
               Models.resolve(fallback(dir), env: Map.delete(env, "ANTHROPIC_API_KEY"))
    end

    test "a chosen model, or --config none, is left alone", %{tmp_dir: dir} do
      env = %{"OPENAI_API_KEY" => "set"}
      chosen = chosen(fallback(dir), "test:mine", :flag)

      assert Models.resolve(chosen, env: env) == chosen
      assert Models.resolve(fallback(nil), env: env) == fallback(nil)

      assert {:ok, hermetic} = Options.parse(["--config", "none"])
      assert Models.resolve(hermetic, env: env) == hermetic
    end

    # A read-only home, a CI container: the default config file cannot be
    # created, and that used to be taken for `--config none`, so the key the
    # container was given was ignored and the run asked for another vendor's.
    test "a home directory lmx cannot write to still honours the keys that are set",
         %{tmp_dir: dir} do
      locked = Path.join(dir, "locked")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o500)
      on_exit(fn -> File.chmod(locked, 0o700) end)

      {:ok, config} = Config.load_default(Path.join([locked, ".lmx", "config.json"]), "x:y")
      unwritable = %{fallback(nil) | config: config}

      assert %{model: "openai:gpt-6-sol", host: %{model_source: :credential}} =
               Models.resolve(unwritable, env: %{"OPENAI_API_KEY" => "set"})

      assert %{model: "ollama:qwen3:8b", host: %{model_source: :ollama}} =
               Models.local(
                 unwritable,
                 [env: %{}] ++ ollama([tag("qwen3:8b", nil, ["completion", "tools"])])
               )
    end
  end

  describe "local/2 picking a model Ollama serves" do
    test "a keyless default moves to a tool-capable tag, never an embedding model",
         %{tmp_dir: dir} do
      # Sorted by name, the embedding models come first, which is what the
      # old pick took.
      tags = [
        tag("all-minilm:latest", "2026-09-01T00:00:00Z", ["embedding"]),
        tag("llama3.2:1b", "2026-09-02T00:00:00Z"),
        tag("nomic-embed-text:latest", "2026-09-03T00:00:00Z"),
        tag("qwen3:8b", "2026-08-01T00:00:00Z")
      ]

      shows = %{
        "llama3.2:1b" => shown(["completion"]),
        "nomic-embed-text:latest" => shown(["embedding"]),
        "qwen3:8b" => shown(["completion", "tools", "thinking"], 40_960)
      }

      assert %{model: "ollama:qwen3:8b", host: %{model_source: :ollama, local_model: local}} =
               Models.local(fallback(dir), [env: %{}] ++ ollama(tags, shows))

      # The trained length, read so later code can compare it with the
      # window Ollama actually serves.
      assert local.context_length == 40_960
      assert "tools" in local.capabilities
    end

    # Picked with no word, a newcomer's session ran on Ollama's default
    # window — 4096 tokens under 24 GiB of GPU memory — and lost its task.
    test "says which local model it picked, and what Ollama's window needs", %{tmp_dir: dir} do
      options = %{fallback(dir) | config: %Config{personal: true}}
      serving = ollama([tag("qwen3:8b", nil, ["completion", "tools"])])

      assert %{model: "ollama:qwen3:8b", config: config} =
               Models.local(options, [env: %{}] ++ serving)

      assert [notice] = Config.warnings(config)
      assert [found, remedy] = String.split(notice, "; ", parts: 2)
      assert found =~ "ollama:qwen3:8b"
      assert remedy =~ "set OLLAMA_CONTEXT_LENGTH to 32768 or more (65536 recommended)"
      assert remedy =~ "--model"
    end

    test "prefers the local model lmx used last, then the newest tag", %{tmp_dir: dir} do
      tags = [
        tag("gemma4:12b", "2026-08-03T11:25:27.769415285-06:00", ["completion", "tools"]),
        tag("qwen3.8:27b", "2026-08-14T14:06:18.052262684-06:00", ["completion", "tools"])
      ]

      shows = %{
        "gemma4:12b" => shown(["completion", "tools"]),
        "qwen3.8:27b" => shown(["completion", "tools"])
      }

      assert %{model: "ollama:qwen3.8:27b"} =
               Models.local(fallback(dir), [env: %{}] ++ ollama(tags, shows))

      :ok = State.remember_model(dir, "ollama:gemma4:12b", chosen?: false)

      assert %{model: "ollama:gemma4:12b", host: %{model_source: :ollama}} =
               Models.local(fallback(dir), [env: %{}] ++ ollama(tags, shows))
    end

    test "nothing served that can call tools leaves the default where it was",
         %{tmp_dir: dir} do
      tags = [tag("all-minilm:latest", nil, ["embedding"])]

      assert Models.local(fallback(dir), [env: %{}] ++ ollama(tags)) == fallback(dir)
      assert Models.local(fallback(dir), [env: %{}] ++ no_daemon()) == fallback(dir)
      refute_received {:shown, _name}
    end

    test "a model with a key, or a hermetic run, never asks the daemon", %{tmp_dir: dir} do
      never = [
        ollama: [
          get: fn _url, _opts -> flunk("Ollama was asked") end,
          post: fn _url, _opts -> flunk("Ollama was asked") end
        ]
      ]

      keyed = [env: %{"ANTHROPIC_API_KEY" => "set"}] ++ never
      assert Models.local(fallback(dir), keyed) == fallback(dir)

      assert {:ok, hermetic} = Options.parse(["--config", "none"])
      assert Models.local(hermetic, [env: %{}] ++ never) == hermetic
    end

    # The hosts hand their whole option list over, and `:get` there belongs
    # to the update check; only `:ollama` is the daemon's.
    test "only the :ollama options reach the daemon", %{tmp_dir: dir} do
      opts =
        [env: %{}, get: fn _url, _opts -> flunk("another request's :get asked Ollama") end] ++
          ollama([tag("qwen3:8b", nil, ["completion", "tools"])])

      assert %{model: "ollama:qwen3:8b"} = Models.local(fallback(dir), opts)
    end
  end

  describe "what is remembered" do
    test "only a model a person chose becomes the one to start on next time",
         %{tmp_dir: dir} do
      for source <- [:ollama, :credential, :fallback] do
        :ok = Models.remember(chosen(fallback(dir), "ollama:qwen3:8b", source), "ollama:qwen3:8b")
      end

      assert State.last_model(dir) == nil
      assert State.recent_models(dir) == ["ollama:qwen3:8b"]

      :ok = Models.remember(chosen(fallback(dir), "openai:gpt-6-sol", :flag), "openai:gpt-6-sol")
      assert State.last_model(dir) == "openai:gpt-6-sol"
      assert State.recent_models(dir) == ["openai:gpt-6-sol", "ollama:qwen3:8b"]
    end

    # Found by the launch audit: one session on a local model, then a key
    # set and Ollama stopped, and every later start still went to Ollama
    # and failed with a bare `connection refused`.
    test "a key set later outranks a remembered local model Ollama no longer serves",
         %{tmp_dir: dir} do
      :ok = State.remember_model(dir, "ollama:gemma4:12b")
      env = %{"ANTHROPIC_API_KEY" => "set"}

      remembered = Models.resolve(fallback(dir), env: env)
      assert %{model: "ollama:gemma4:12b", host: %{model_source: :last_used}} = remembered

      assert %{model: "anthropic:claude-sonnet-5", host: %{model_source: :credential}} =
               Models.local(remembered, [env: env] ++ no_daemon())

      gone = ollama([tag("qwen3:8b", nil, ["completion", "tools"])])

      assert %{model: "anthropic:claude-sonnet-5"} =
               Models.local(remembered, [env: env] ++ gone)

      # Without a key, another local model is still better than one that
      # is not there; with nothing at all, the placeholder.
      assert %{model: "ollama:qwen3:8b", host: %{model_source: :ollama}} =
               Models.local(remembered, [env: %{}] ++ gone)

      assert %{model: placeholder, host: %{model_source: :fallback}} =
               Models.local(remembered, [env: %{}] ++ no_daemon())

      assert placeholder == Options.default_model()

      # While the daemon serves it, the person's choice stands.
      serving = ollama([tag("gemma4:12b", nil, ["completion", "tools"])])

      assert %{model: "ollama:gemma4:12b", host: %{model_source: :last_used}} =
               Models.local(remembered, [env: env] ++ serving)
    end

    # `/api/tags` lists `llama3.2:latest`, and people write `ollama:llama3.2`.
    # Compared as written, the model looked gone, and a key set for something
    # else took the person off their own choice.
    test "a remembered model named without its tag is the one Ollama serves as :latest",
         %{tmp_dir: dir} do
      :ok = State.remember_model(dir, "ollama:llama3.2")
      env = %{"ANTHROPIC_API_KEY" => "set"}
      remembered = Models.resolve(fallback(dir), env: env)

      serving =
        ollama([tag("llama3.2:latest", nil, ["completion", "tools"])], %{
          "llama3.2:latest" => shown(["completion", "tools"], 131_072)
        })

      assert %{model: "ollama:llama3.2", host: %{model_source: :last_used, local_model: local}} =
               Models.local(remembered, [env: env] ++ serving)

      # Described like a model lmx picked, its trained length included.
      assert %{model: "ollama:llama3.2:latest", context_length: 131_072} = local
    end

    test "a remembered model that is not there is dropped out loud, and the daemon asked once",
         %{tmp_dir: dir} do
      :ok = State.remember_model(dir, "ollama:gemma4:12b")
      test = self()

      unreachable = [
        ollama: [
          get: fn _url, _opts ->
            send(test, :tags)
            {:error, %Req.TransportError{reason: :econnrefused}}
          end,
          post: fn _url, _opts -> flunk("nothing answered /api/tags") end
        ]
      ]

      options = %{fallback(dir) | config: %Config{personal: true}}
      remembered = Models.resolve(options, env: %{})

      assert %{host: %{model_source: :fallback}, config: config} =
               Models.local(remembered, [env: %{}] ++ unreachable)

      assert_received :tags
      refute_received :tags

      assert [warning] = Config.warnings(config)
      assert warning =~ "ollama:gemma4:12b, the model you last chose"
      assert warning =~ "Ollama did not answer"

      # With a key, the warning says what lmx started on instead.
      keyed = Models.resolve(options, env: %{"OPENAI_API_KEY" => "set"})
      gone = ollama([tag("qwen3:8b", nil, ["completion", "tools"])])

      assert %{model: "openai:gpt-6-sol", config: config} =
               Models.local(keyed, [env: %{"OPENAI_API_KEY" => "set"}] ++ gone)

      assert [warning] = Config.warnings(config)
      assert warning =~ "Ollama serves no chat model by that name"
      # Split at "; " by the notice box into what happened and what to do.
      assert [_found, remedy] = String.split(warning, "; ", parts: 2)
      assert warning =~ "this session starts on openai:gpt-6-sol"
      assert remedy =~ "ollama pull gemma4:12b"
    end
  end

  describe "credential/3" do
    # An explicitly empty variable switches a saved key off at request time
    # (`Lemieux.Providers.ReqLLM`), so it cannot count as a key here: lmx
    # would start on a provider whose first request is refused.
    test "an empty variable is no key, even with one saved in the config file" do
      config = %Config{settings: %{"providers" => %{"anthropic" => %{"api_key" => "saved"}}}}

      assert Models.credential("anthropic", config, env: %{}) == :present
      assert Models.credential("anthropic", config, env: %{"ANTHROPIC_API_KEY" => ""}) == :missing
      assert Models.credential("anthropic", nil, env: %{"ANTHROPIC_API_KEY" => "set"}) == :present
    end
  end

  describe "missing_key_message/2" do
    test "names no single vendor when nobody chose the model, and never offers /retry",
         %{tmp_dir: dir} do
      message = Models.missing_key_message(fallback(dir))

      assert message =~ "no model credentials found"
      assert message =~ "ANTHROPIC_API_KEY or OPENAI_API_KEY"
      assert message =~ "lmx help models"
      assert message =~ "Ollama"
      refute message =~ "no API key for"
      refute message =~ "/retry"
    end

    test "names the key of a model a person chose" do
      message = Models.missing_key_message(chosen(fallback(nil), "openai:gpt-6-sol", :flag))

      assert message =~ "no API key for openai"
      assert message =~ "OPENAI_API_KEY"
      refute message =~ "/retry"
      # `/provider` switches providers; it saves no key.
      refute message =~ "/provider"
    end

    # `--config none` guesses nothing from keys or a local daemon, and saves
    # no key: "no credentials found" was false with OPENAI_API_KEY set, and
    # the terminal UI's panel and Ollama were no way out.
    test "under --config none, says what that run starts on and why the keys did not count" do
      assert {:ok, hermetic} = Options.parse(["--config", "none"])
      message = Models.missing_key_message(hermetic)

      assert message =~ "--config none"
      assert message =~ Options.default_model()
      assert message =~ "ANTHROPIC_API_KEY"
      assert message =~ "--model PROVIDER:MODEL"
      refute message =~ "no model credentials found"
      refute message =~ "saves one for you"
    end

    test "spells the help command as the host is run", %{tmp_dir: dir} do
      message = Models.missing_key_message(fallback(dir), "mix lmx")

      assert message =~ "mix lmx help models"
      assert message =~ "mix lmx in a terminal"
    end
  end

  describe "first_run/2" do
    test "is described only when the model has no key", %{tmp_dir: dir} do
      options = chosen(fallback(dir), "anthropic:claude-sonnet-5", :flag)

      assert %{provider: "anthropic", providers: [_ | _] = providers} =
               Models.first_run(options, [env: %{}] ++ no_daemon())

      assert Enum.all?(providers, &(&1.credential in [:missing, :present, :not_required]))
      assert Models.first_run(options, env: %{"ANTHROPIC_API_KEY" => "k"}) == nil
    end

    test "preselects no provider when nobody chose one, and the named one otherwise",
         %{tmp_dir: dir} do
      assert %{selected: nil} = Models.first_run(fallback(dir), [env: %{}] ++ no_daemon())

      named = chosen(fallback(dir), "openai:gpt-6-sol", :flag)
      assert %{selected: "openai"} = Models.first_run(named, [env: %{}] ++ no_daemon())
    end

    test "offers a local row with the window caveat when Ollama serves a model that can call tools",
         %{tmp_dir: dir} do
      serving = ollama([tag("qwen3:8b", nil, ["completion", "tools"])])

      assert %{providers: providers, hint: hint} =
               Models.first_run(fallback(dir), [env: %{}] ++ serving)

      assert %{model: "ollama:qwen3:8b", key?: false, label: "Local (Ollama)", note: note} =
               List.last(providers)

      caveat = "set OLLAMA_CONTEXT_LENGTH to 32768 or more (65536 recommended)"
      assert hint =~ caveat
      assert note =~ caveat
    end

    test "says how to get a local model when there is none to offer", %{tmp_dir: dir} do
      assert %{providers: providers, hint: unreachable} =
               Models.first_run(fallback(dir), [env: %{}] ++ no_daemon())

      refute Enum.any?(providers, &(&1[:key?] == false))
      assert unreachable =~ "Ollama"
      assert unreachable =~ "set OLLAMA_CONTEXT_LENGTH to 32768 or more (65536 recommended)"

      embedding_only = ollama([tag("all-minilm:latest", nil, ["embedding"])])

      assert %{hint: none} = Models.first_run(fallback(dir), [env: %{}] ++ embedding_only)
      assert none =~ "none of its models can call tools"
      # The hint people follow just before their first local session.
      assert none =~ "set OLLAMA_CONTEXT_LENGTH to 32768 or more (65536 recommended)"
    end

    # The panel's own sentence said "no model credentials were found" under
    # `--config none` with another provider's key set, and for a model the
    # person named while other keys were there.
    test "explains a hermetic run and a named model rather than claiming no keys",
         %{tmp_dir: dir} do
      assert %{intro: nil} = Models.first_run(fallback(dir), [env: %{}] ++ no_daemon())

      assert {:ok, hermetic} = Options.parse(["--config", "none"])
      env = %{"OPENAI_API_KEY" => "set"}
      assert %{intro: intro, providers: providers} = Models.first_run(hermetic, env: env)

      assert intro =~ "--config none"
      refute intro =~ "No model credentials"
      assert %{credential: :present} = Enum.find(providers, &(&1.id == "openai"))

      named = chosen(fallback(dir), "openai:gpt-6-sol", :flag)
      assert %{intro: intro} = Models.first_run(named, [env: %{}] ++ no_daemon())
      assert intro =~ "openai:gpt-6-sol"
    end
  end
end
