defmodule Lemieux.CLI.OllamaTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Ollama
  alias Lemieux.CLI.Options

  test "Ixway routing skips all direct Ollama discovery" do
    assert {:ok, options} = Options.parse(["--ixway", "http://localhost:4003"])

    assert Ollama.models(options,
             get: fn _, _ -> flunk("direct discovery in Ixway mode") end,
             api_key: "unused"
           ) == []
  end

  test "discovers every installed local tag without an API key" do
    owner = self()

    get = fn url, opts ->
      send(owner, {:get, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "models" => [
             %{"name" => "qwen3.8:27b-mxfp8"},
             %{"model" => "devstral:latest"},
             %{"name" => "qwen3.8:27b-mxfp8"}
           ]
         }
       }}
    end

    assert {:ok, options} = Options.parse([])

    assert Ollama.models(options, get: get, api_key: nil) == [
             "ollama:devstral:latest",
             "ollama:qwen3.8:27b-mxfp8"
           ]

    assert_receive {:get, "http://localhost:11434/api/tags", request_opts}
    assert request_opts[:retry] == false
    assert is_integer(request_opts[:receive_timeout])
    assert request_opts[:connect_options][:timeout] <= request_opts[:receive_timeout]
  end

  test "uses an explicit remote Ollama base when Ollama is the selected provider" do
    owner = self()

    get = fn url, _opts ->
      send(owner, {:get, url})
      {:ok, %Req.Response{status: 200, body: %{"models" => []}}}
    end

    assert {:ok, options} =
             Options.parse([
               "--model",
               "ollama:qwen3.8:27b-mxfp8",
               "--base-url",
               "http://model-host:11434/ollama/v1"
             ])

    assert Ollama.models(options, get: get, api_key: nil) == []
    assert_receive {:get, "http://model-host:11434/ollama/api/tags"}
  end

  test "does not mistake another provider's gateway for Ollama" do
    owner = self()

    get = fn url, _opts ->
      send(owner, {:get, url})
      {:error, :econnrefused}
    end

    assert {:ok, options} =
             Options.parse([
               "--model",
               "anthropic:claude-sonnet-5",
               "--base-url",
               "https://gateway.example/anthropic"
             ])

    assert Ollama.models(options, get: get, api_key: nil) == []
    assert_receive {:get, "http://localhost:11434/api/tags"}
  end

  test "discovers Ollama Cloud models with bearer authentication" do
    owner = self()

    get = fn
      "http://localhost:11434/api/tags" = url, _opts ->
        send(owner, {:get, url})
        {:error, :econnrefused}

      "https://ollama.com/api/tags" = url, opts ->
        send(owner, {:get, url, opts[:headers]})

        {:ok,
         %Req.Response{
           status: 200,
           body: %{"models" => [%{"name" => "gpt-oss:120b"}, %{"model" => "glm-5.2"}]}
         }}
    end

    assert {:ok, options} = Options.parse([])

    assert Ollama.models(options, get: get, api_key: "cloud-key") == [
             "ollama_cloud:glm-5.2",
             "ollama_cloud:gpt-oss:120b"
           ]

    assert_receive {:get, "http://localhost:11434/api/tags"}

    assert_receive {:get, "https://ollama.com/api/tags", [{"authorization", "Bearer cloud-key"}]}
  end

  test "an absent or malformed daemon is simply not offered" do
    assert {:ok, options} = Options.parse([])

    assert Ollama.models(options,
             get: fn _url, _opts -> {:error, :econnrefused} end,
             api_key: nil
           ) == []

    assert Ollama.models(options,
             get: fn _url, _opts ->
               {:ok, %Req.Response{status: 503, body: "starting"}}
             end,
             api_key: nil
           ) == []

    assert Ollama.models(options,
             get: fn _url, _opts ->
               {:ok, %Req.Response{status: 200, body: %{"models" => "not-a-list"}}}
             end,
             api_key: nil
           ) == []
  end

  describe "local_model/2" do
    defp tags_answer(models),
      do: fn _url, _opts -> {:ok, %Req.Response{status: 200, body: %{"models" => models}}} end

    test "asks /api/show for tools and the trained context length, waiting longer than completion" do
      test = self()

      get = fn url, opts ->
        send(test, {:tags, url, opts[:receive_timeout]})
        {:ok, %Req.Response{status: 200, body: %{"models" => [%{"name" => "gemma4:12b"}]}}}
      end

      post = fn url, opts ->
        send(test, {:show, url, opts[:json]})

        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "capabilities" => ["completion", "vision", "tools"],
             "model_info" => %{
               "general.architecture" => "gemma4",
               "gemma4.context_length" => 262_144
             }
           }
         }}
      end

      assert {:ok, options} = Options.parse([])

      assert {:ok, %{model: "ollama:gemma4:12b", context_length: 262_144}} =
               Ollama.local_model(options, get: get, post: post)

      assert_receive {:tags, "http://localhost:11434/api/tags", probe_timeout}
      assert_receive {:show, "http://localhost:11434/api/show", %{"model" => "gemma4:12b"}}
      assert probe_timeout > 500
    end

    test "a daemon too old to report capabilities still never gets an embedding model" do
      models = [
        %{
          "name" => "all-minilm:latest",
          "modified_at" => "2026-09-02T00:00:00Z",
          "details" => %{"family" => "bert"}
        },
        %{
          "name" => "mxbai-embed-large:latest",
          "modified_at" => "2026-09-03T00:00:00Z",
          "details" => %{"family" => "xlm"}
        },
        %{
          "name" => "llama3.2:latest",
          "modified_at" => "2026-09-01T00:00:00Z",
          "details" => %{"family" => "llama"}
        }
      ]

      post = fn _url, _opts -> {:ok, %Req.Response{status: 200, body: %{"license" => "x"}}} end

      assert {:ok, options} = Options.parse([])

      assert {:ok, %{model: "ollama:llama3.2:latest", capabilities: nil}} =
               Ollama.local_model(options, get: tags_answer(models), post: post)
    end

    test "a daemon that stops answering /api/show is asked no more, and its tags decide" do
      test = self()

      models = [
        %{
          "name" => "a:1",
          "modified_at" => "2026-09-02T00:00:00Z",
          "capabilities" => ["completion"]
        },
        %{
          "name" => "b:1",
          "modified_at" => "2026-09-01T00:00:00Z",
          "details" => %{"family" => "bert"}
        },
        %{"name" => "c:1", "modified_at" => "2026-08-01T00:00:00Z", "capabilities" => ["tools"]}
      ]

      post = fn _url, opts ->
        send(test, {:show, opts[:json]["model"]})
        {:error, %Req.TransportError{reason: :timeout}}
      end

      assert {:ok, options} = Options.parse([])

      # `a:1` is ruled out by its tags alone; `b:1`'s description times out,
      # leaving its embedding family to rule it out, and `c:1` is judged on
      # what `/api/tags` said rather than waited for again.
      assert {:ok, %{model: "ollama:c:1"}} =
               Ollama.local_model(options, get: tags_answer(models), post: post)

      assert_received {:show, "b:1"}
      refute_received {:show, _other}
    end

    test "says whether the daemon was not there or had nothing to offer" do
      assert {:ok, options} = Options.parse([])
      refused = fn _url, _opts -> {:error, %Req.TransportError{reason: :econnrefused}} end
      never = fn _url, _opts -> flunk("nothing to describe") end

      assert Ollama.local_model(options, get: refused, post: never) == {:error, :unreachable}

      embedding = [%{"name" => "all-minilm:latest", "capabilities" => ["embedding"]}]

      assert Ollama.local_model(options, get: tags_answer(embedding), post: never) ==
               {:error, :none}

      assert Ollama.local_model(options, get: tags_answer([]), post: never) == {:error, :none}
    end

    # `/api/tags` names every tag in full, and people write `ollama:gemma4`;
    # the most recently used model ranked nothing when the two were compared
    # as strings.
    test "ranks a recently used model named without its tag" do
      models = [
        %{
          "name" => "qwen3:8b",
          "modified_at" => "2026-09-02T00:00:00Z",
          "capabilities" => ["tools"]
        },
        %{
          "name" => "gemma4:latest",
          "modified_at" => "2026-08-01T00:00:00Z",
          "capabilities" => ["tools"]
        }
      ]

      show = fn _url, _opts -> {:ok, %Req.Response{status: 200, body: %{}}} end
      assert {:ok, options} = Options.parse([])

      assert {:ok, %{model: "ollama:gemma4:latest"}} =
               Ollama.local_model(options,
                 get: tags_answer(models),
                 post: show,
                 recent: ["openai:gpt-6-sol", "ollama:Gemma4"]
               )
    end

    # A model whose `model_info` holds two context lengths — a vision tower's
    # beside the language model's — and in a map small enough to iterate in
    # key order, where the tower's sorts first.
    test "reads the context length of the model's own architecture" do
      shown = %{
        "capabilities" => ["completion", "vision", "tools"],
        "model_info" => %{
          "general.architecture" => "mllama",
          "clip.context_length" => 77,
          "mllama.context_length" => 131_072
        }
      }

      get = tags_answer([%{"name" => "llama3.2-vision:11b"}])
      post = fn _url, _opts -> {:ok, %Req.Response{status: 200, body: shown}} end
      assert {:ok, options} = Options.parse([])

      assert {:ok, %{context_length: 131_072}} =
               Ollama.local_model(options, get: get, post: post)
    end
  end

  describe "serving/3" do
    defp daemon(models, shown \\ %{}) do
      test = self()

      [
        get: fn _url, _opts -> {:ok, %Req.Response{status: 200, body: %{"models" => models}}} end,
        post: fn _url, opts ->
          send(test, {:show, opts[:json]["model"]})
          {:ok, %Req.Response{status: 200, body: shown}}
        end
      ]
    end

    # Ollama compares names the way `ollama run` does: without a tag a name
    # means `:latest`, the default registry and namespace may be spelled out,
    # and case does not matter.
    test "finds the tag a model names, however the person spelled it" do
      assert {:ok, options} = Options.parse([])

      shown = %{
        "capabilities" => ["completion", "tools"],
        "model_info" => %{"llama.context_length" => 131_072}
      }

      served = daemon([%{"name" => "llama3.2:latest"}, %{"name" => "qwen3:8b"}], shown)

      for name <-
            ~w(ollama:llama3.2 ollama:llama3.2:latest ollama:Llama3.2 ollama:library/llama3.2
                     ollama:registry.ollama.ai/library/llama3.2:latest) do
        assert {:ok, %{model: "ollama:llama3.2:latest", context_length: 131_072}} =
                 Ollama.serving(options, name, served),
               name
      end

      assert_received {:show, "llama3.2:latest"}
      assert {:error, :none} = Ollama.serving(options, "ollama:llama3.2:1b", served)
      assert {:error, :none} = Ollama.serving(options, "ollama:qwen3", served)
    end

    test "says whether the daemon was not there, or serves nothing by that name that can chat" do
      assert {:ok, options} = Options.parse([])
      refused = [get: fn _url, _opts -> {:error, %Req.TransportError{reason: :econnrefused}} end]

      assert Ollama.serving(options, "ollama:llama3.2", refused) == {:error, :unreachable}

      embedding =
        daemon([%{"name" => "nomic-embed-text:latest", "capabilities" => ["embedding"]}])

      assert Ollama.serving(options, "ollama:nomic-embed-text", embedding) == {:error, :none}
    end
  end

  # The completion list feeds `/provider ollama`, which switches to the first
  # local model offered — alphabetically, the embedding models.
  test "offers no model that cannot chat" do
    models = [
      %{"name" => "all-minilm:latest", "details" => %{"family" => "bert"}},
      %{"name" => "bge-m3:latest", "capabilities" => ["embedding"]},
      %{"name" => "mxbai-embed-large:latest"},
      %{"name" => "gemma3:4b", "capabilities" => ["completion", "vision"]},
      %{"name" => "qwen3:8b", "capabilities" => ["completion", "tools"]}
    ]

    get = fn _url, _opts -> {:ok, %Req.Response{status: 200, body: %{"models" => models}}} end
    assert {:ok, options} = Options.parse([])

    assert Ollama.models(options, get: get, api_key: nil) == [
             "ollama:gemma3:4b",
             "ollama:qwen3:8b"
           ]
  end
end
