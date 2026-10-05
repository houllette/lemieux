defmodule Lemieux.TUI.ProviderDiscoveryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.CLI.SessionIndex
  alias Lemieux.TUI
  alias Lemieux.TUI.CatalogState

  # What `/provider ollama` switches to when the session lists no Ollama model
  # of its own and the host found some. The stand-in session answers
  # `{:provider_unavailable, "ollama"}`, as a real one does for a provider its
  # catalog does not list, so every switch below is the discovered fallback.
  # The host's discovery is stubbed by sending the message the screen gets;
  # `Lemieux.CLI.TUIDiscoveryTest` covers what `lmx` itself sends.

  @found [
    {:preferred, "ollama:qwen3:8b"},
    "ollama:devstral:latest",
    "ollama:llama3.1:8b"
  ]

  defp ollama_session(id \\ "01SESSION"),
    do: fake_session(snapshot(id), unavailable_providers: ["ollama"])

  defp discovered(state, models) do
    assert {:noreply, state} = TUI.handle_info({:models_discovered, models}, state)
    state
  end

  defp switched_to(state) do
    command(state, "/provider ollama")
    assert_receive {:set_provider, "ollama"}
    assert_receive {:set_model, model}
    model
  end

  describe "/provider ollama" do
    test "switches to the model the host prefers, not the first in the alphabet" do
      state = tui(session: ollama_session()) |> discovered(@found)

      assert switched_to(state) == "ollama:qwen3:8b"
    end

    test "a model the person used recently comes first when the host found it" do
      recent = %SessionIndex{id: "02RECENT", model: "ollama:llama3.1:8b"}
      state = tui(session: ollama_session(), sessions: [recent]) |> discovered(@found)

      assert switched_to(state) == "ollama:llama3.1:8b"
    end

    # The host leaves out models that cannot call tools, so a session that
    # ran on one is passed over rather than gone back to.
    test "a recently used model the host does not offer is passed over" do
      recent = %SessionIndex{id: "02RECENT", model: "ollama:gemma3:1b"}
      state = tui(session: ollama_session(), sessions: [recent]) |> discovered(@found)

      assert switched_to(state) == "ollama:qwen3:8b"
    end

    test "the model the person configured comes before the host's" do
      state =
        tui(
          session: ollama_session(),
          preferred_models: %{"ollama" => "ollama:devstral:latest"}
        )
        |> discovered(@found)

      assert switched_to(state) == "ollama:devstral:latest"
    end

    # Ollama answered with nothing that can call tools, and the host offered
    # none of it: the model last used is not gone back to either.
    test "with nothing found for the provider, nothing is switched to" do
      recent = %SessionIndex{id: "02RECENT", model: "ollama:gemma3:1b"}

      state =
        tui(session: ollama_session(), sessions: [recent])
        |> discovered(["lmstudio:qwen3-8b"])

      said = command(state, "/provider ollama")

      assert_receive {:set_provider, "ollama"}
      refute_received {:set_model, _model}
      assert unwrapped(said) =~ "could not switch provider: ollama has no available models"
    end

    # Discovery usually answers while the session is still being prepared,
    # and starting it rebuilds the screen's catalog from the host's options:
    # only the discovered list is carried across, so the preference has to be
    # in it.
    test "the host's preference outlives the session starting after it arrived" do
      {:ok, tasks} = Task.Supervisor.start_link()
      owner = self()
      session = ollama_session("02DISCOVER")

      start = fn app ->
        send(owner, {:preparing, app, self()})

        receive do
          :finish_preparing -> {:ok, session, [preferred_models: %{}]}
        end
      end

      {:ok, app} =
        TUI.start_link(test_mode: {80, 24}, name: nil, start_async: start, task_supervisor: tasks)

      assert_receive {:preparing, ^app, preparation}
      send(app, {:models_discovered, @found})
      :ok = LemieuxTest.Sync.state(app, &(&1.user_state.catalog.discovered != []))
      assert :sys.get_state(app).user_state.session == nil

      send(preparation, :finish_preparing)
      :ok = LemieuxTest.Sync.state(app, &(&1.user_state.id == "02DISCOVER"))

      assert switched_to(:sys.get_state(app).user_state) == "ollama:qwen3:8b"
    end
  end

  describe "CatalogState.discover/3" do
    test "puts each preferred model first and the rest in alphabetical order" do
      catalog =
        CatalogState.discover(
          tui().catalog,
          ["ollama:zephyr:7b", {:preferred, "ollama:qwen3:8b"}, "ollama:aya:8b"],
          "test"
        )

      assert catalog.discovered == ["ollama:qwen3:8b", "ollama:aya:8b", "ollama:zephyr:7b"]
    end

    test "a later discovery adds to the list without reordering what was found" do
      first = CatalogState.discover(tui().catalog, @found, "test")

      later =
        CatalogState.discover(first, ["ollama_cloud:gpt-oss:120b", "ollama:aya:8b"], "test")

      assert later.discovered == [
               "ollama:qwen3:8b",
               "ollama:devstral:latest",
               "ollama:llama3.1:8b",
               "ollama:aya:8b",
               "ollama_cloud:gpt-oss:120b"
             ]
    end

    test "what is not a model spec is dropped, preferred or not" do
      catalog =
        CatalogState.discover(
          tui().catalog,
          [{:preferred, "no-provider"}, {:preferred, 42}, :ollama, "ollama:qwen3:8b"],
          "test"
        )

      assert catalog.discovered == ["ollama:qwen3:8b"]
    end

    # `/provider` reads the host's preference from the order alone; the
    # person's configured choices stay theirs, and the menu labels only those
    # "preferred".
    test "the host's preference is not recorded as the person's" do
      catalog = CatalogState.discover(tui().catalog, @found, "ollama")

      assert catalog.preferred_models == %{}
      assert CatalogState.selection_preferences(catalog) == %{}
    end
  end
end
