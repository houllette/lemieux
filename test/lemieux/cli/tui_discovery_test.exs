defmodule Lemieux.CLI.TUIDiscoveryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.TUI

  # What `lmx` tells the screen a local Ollama serves, and so what
  # `/provider ollama` switches to. The daemon is a pair of stubs answering
  # `/api/tags` and `/api/show`; nothing here reaches a real one.

  # An embedding model, a chat model that cannot call tools, and two that
  # can, the one pulled most recently sorting last.
  @tags [
    %{
      "name" => "all-minilm:latest",
      "modified_at" => "2026-09-20T00:00:00Z",
      "capabilities" => ["embedding"]
    },
    %{
      "name" => "gemma3:1b",
      "modified_at" => "2026-09-10T00:00:00Z",
      "capabilities" => ["completion"]
    },
    %{
      "name" => "llama3.1:8b",
      "modified_at" => "2026-08-01T00:00:00Z",
      "capabilities" => ["completion", "tools"]
    },
    %{
      "name" => "qwen3:8b",
      "modified_at" => "2026-09-01T00:00:00Z",
      "capabilities" => ["completion", "tools", "thinking"]
    }
  ]

  setup do
    {:ok, options} = Options.parse(["--config", "none"])
    %{options: options}
  end

  # `/api/show` describes each tag as `shown` says, by default as `/api/tags`
  # listed it.
  defp daemon(tags, opts \\ []) do
    test = self()
    shown = Keyword.get(opts, :shown, Map.new(tags, &{&1["name"], &1["capabilities"]}))

    [
      get: fn url, _request ->
        send(test, {:get, url})
        {:ok, %Req.Response{status: 200, body: %{"models" => tags}}}
      end,
      post: fn _url, request ->
        name = request[:json]["model"]
        send(test, {:show, name})
        {:ok, %Req.Response{status: 200, body: %{"capabilities" => Map.get(shown, name)}}}
      end,
      recent: Keyword.get(opts, :recent, []),
      api_key: nil
    ]
  end

  describe "discovered_models/2" do
    test "leads with the model lmx would start on and leaves out what cannot call tools",
         %{options: options} do
      assert TUI.discovered_models(options, ollama: daemon(@tags)) == [
               {:preferred, "ollama:qwen3:8b"},
               "ollama:llama3.1:8b"
             ]
    end

    test "the model used most recently leads, as it would on a first start",
         %{options: options} do
      ollama = daemon(@tags, recent: ["anthropic:claude-sonnet-5", "ollama:llama3.1:8b"])

      assert TUI.discovered_models(options, ollama: ollama) == [
               {:preferred, "ollama:llama3.1:8b"},
               "ollama:qwen3:8b"
             ]
    end

    # Without capabilities in `/api/tags` a chat model cannot be ruled out
    # there, so it is offered; the one switched to is the one `/api/show`
    # says can call tools.
    test "a daemon that lists no capabilities offers its chat models, led by one that has tools",
         %{options: options} do
      shown = Map.new(@tags, &{&1["name"], &1["capabilities"]})

      unlisted =
        Enum.map(@tags, fn tag ->
          tag
          |> Map.delete("capabilities")
          |> Map.put("details", %{"family" => family(tag["name"])})
        end)

      assert TUI.discovered_models(options, ollama: daemon(unlisted, shown: shown)) == [
               {:preferred, "ollama:qwen3:8b"},
               "ollama:gemma3:1b",
               "ollama:llama3.1:8b"
             ]

      assert_received {:show, "gemma3:1b"}
      refute_received {:show, "llama3.1:8b"}
    end

    test "nothing that can call tools offers nothing local to switch to",
         %{options: options} do
      without = Enum.reject(@tags, &("tools" in &1["capabilities"]))

      assert TUI.discovered_models(options, ollama: daemon(without)) == []
    end

    test "a daemon that does not answer offers nothing and is not asked to describe anything",
         %{options: options} do
      refused = fn _url, _request -> {:error, %Req.TransportError{reason: :econnrefused}} end
      never = fn _url, _request -> flunk("nothing to describe") end

      assert TUI.discovered_models(options,
               ollama: [get: refused, post: never, recent: [], api_key: nil]
             ) == []
    end
  end

  # The list goes to the screen as `lmx` sends it, and `/provider ollama`
  # lands on the model `lmx` would have started on: alphabetically it was
  # `gemma3:1b`, which cannot call tools.
  test "/provider ollama on a running screen switches to the model lmx would start on",
       %{options: options} do
    models = TUI.discovered_models(options, ollama: daemon(@tags))
    session = fake_session(snapshot("01SESSION"), unavailable_providers: ["ollama"])

    assert {:noreply, state} =
             Lemieux.TUI.handle_info({:models_discovered, models}, tui(session: session))

    command(state, "/provider ollama")

    assert_receive {:set_provider, "ollama"}
    assert_receive {:set_model, "ollama:qwen3:8b"}
  end

  # After a failed start, `/provider ollama` starts again on a model of the
  # daemon's (`Lemieux.TUI.Lifecycle.restart/2`). It used to find none, start
  # again on the model that had just failed, and say it was starting with
  # Ollama.
  describe "restart_options/3" do
    test "/provider ollama starts again on the model lmx would start on", %{options: options} do
      assert {:ok, restarted} =
               TUI.restart_options(options, [provider: "ollama"], ollama: daemon(@tags))

      assert restarted.model == "ollama:qwen3:8b"
      assert restarted.host.model_source == :flag
    end

    test "the model used most recently leads, as on a first start", %{options: options} do
      ollama = daemon(@tags, recent: ["ollama:llama3.1:8b"])

      assert {:ok, %{model: "ollama:llama3.1:8b"}} =
               TUI.restart_options(options, [provider: "Ollama "], ollama: ollama)
    end

    # The screen runs an Ixway route beside the direct providers, and
    # discovery asks the daemon past it; so does this.
    test "an Ixway route does not stop the daemon being asked", %{options: options} do
      routed = %{options | ixway: "https://ixway.example/v1"}

      assert {:ok, %{model: "ollama:qwen3:8b"}} =
               TUI.restart_options(routed, [provider: "ollama"], ollama: daemon(@tags))
    end

    @tag :tmp_dir
    test "a model configured for Ollama is started on without asking the daemon",
         %{tmp_dir: dir} do
      path = Path.join(dir, "config.json")

      File.write!(
        path,
        JSON.encode!(%{"providers" => %{"ollama" => %{"model" => "ollama:devstral:latest"}}})
      )

      {:ok, options} = Options.parse(["--config", path])
      never = fn _url, _request -> flunk("the daemon was asked") end

      assert {:ok, %{model: "ollama:devstral:latest"}} =
               TUI.restart_options(options, [provider: "ollama"],
                 ollama: [get: never, post: never, recent: []]
               )
    end

    test "a daemon that does not answer fails the start again, saying so",
         %{options: options} do
      refused = fn _url, _request -> {:error, %Req.TransportError{reason: :econnrefused}} end

      assert {:error, message} =
               TUI.restart_options(options, [provider: "ollama"],
                 ollama: [get: refused, post: refused, recent: []]
               )

      assert message =~ "Ollama did not answer"
      assert message =~ "/provider ollama tries again"
    end

    test "a daemon with nothing that can call tools fails the start again, saying so",
         %{options: options} do
      without = Enum.reject(@tags, &("tools" in &1["capabilities"]))

      assert {:error, message} =
               TUI.restart_options(options, [provider: "ollama"], ollama: daemon(without))

      assert message =~ "none of its models can call tools"
      assert message =~ "ollama pull"
    end

    test "/model, and the providers with a recommended model, are as they were",
         %{options: options} do
      never = [get: fn _url, _request -> flunk("the daemon was asked") end, recent: []]

      assert {:ok, %{model: "openai:gpt-5"}} =
               TUI.restart_options(options, [model: "openai:gpt-5"], ollama: never)

      recommended =
        Enum.find_value(Models.recommended(), &(&1.provider == "openai" && &1.model))

      assert {:ok, %{model: ^recommended}} =
               TUI.restart_options(options, [provider: "openai"], ollama: never)

      assert {:ok, ^options} = TUI.restart_options(options, [provider: "lmstudio"], ollama: never)
      assert {:ok, ^options} = TUI.restart_options(options, [], ollama: never)
    end
  end

  defp family("all-minilm" <> _tag), do: "bert"
  defp family(name), do: name |> String.split(~r/[:.]/) |> hd()
end
