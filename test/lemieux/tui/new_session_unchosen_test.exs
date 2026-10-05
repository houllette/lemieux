defmodule Lemieux.TUI.NewSessionUnchosenTest do
  # `/new` on a placeholder nobody chose — a keyless start that skipped the
  # provider panel — starts on that same placeholder. The rebuilt
  # conversation used to count it as chosen, so the first prompt's
  # missing-key line named the placeholder's vendor again after `/new`.
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Conversation
  alias Lemieux.TUI

  @placeholder "anthropic:claude-sonnet-5"
  @missing {:missing_api_key, "anthropic", ":api_key option or ANTHROPIC_API_KEY env var"}

  defp unchosen_screen(next_model) do
    previous = fake_session(%{snapshot("01PLACEHOLDER") | model: @placeholder})
    fresh = fake_session(%{snapshot("02FRESH") | model: next_model})

    state =
      tui(session: previous, new_session: fn _subscriber -> {:ok, fresh} end)
      |> put_in([Access.key!(:resume), :task_supervisor], start_supervised!(Task.Supervisor))
      |> Map.update!(:conversation, &Conversation.unchosen(%{&1 | model: @placeholder}))

    refute state.conversation.model_chosen?
    state
  end

  defp new(state) do
    state = command(state, "/new")
    assert_receive {:new_result, result}
    assert {:noreply, switched} = TUI.handle_info({:new_result, result}, state)
    switched
  end

  test "/new on the placeholder is still a start nobody chose" do
    fresh = @placeholder |> unchosen_screen() |> new()

    assert fresh.id == "02FRESH"
    refute fresh.conversation.model_chosen?

    text = fresh |> info({:error, @missing}) |> unwrapped()
    assert text =~ "no provider key was found"
    refute text =~ "no API key for anthropic"
  end

  test "a new session on another model is not the placeholder" do
    fresh = "xai:grok-4.7" |> unchosen_screen() |> new()

    assert fresh.conversation.model_chosen?
  end

  describe "after switching away from the placeholder" do
    # A keyless start's setup, as `Lemieux.CLI.Models.first_run/2` makes it:
    # nobody chose, and no row's key is set. Esc on the panel keeps it.
    defp keyless do
      %{
        model: @placeholder,
        selected: nil,
        config_path: nil,
        providers: [
          row("anthropic", :missing),
          row("openai", :missing),
          %{id: "ollama", label: "Local (Ollama)", key?: false, model: "ollama:qwen3:8b"}
        ]
      }
    end

    defp row(id, credential),
      do: %{
        id: id,
        label: id,
        env: String.upcase(id) <> "_API_KEY",
        model: id <> ":m",
        credential: credential
      }

    # The screen after Esc and `/provider ollama`: the open session is on a
    # model the person chose, and `/new` starts on the startup placeholder.
    defp switched_away(setup) do
      previous = fake_session(%{snapshot("01OLLAMA") | model: "ollama:qwen3:8b"})
      fresh = fake_session(%{snapshot("02FRESH") | model: @placeholder})

      state =
        tui(session: previous, new_session: fn _subscriber -> {:ok, fresh} end)
        |> put_in([Access.key!(:resume), :task_supervisor], start_supervised!(Task.Supervisor))
        |> put_in([Access.key!(:session_view), :first_run], setup)
        |> Map.update!(:conversation, &%{&1 | model: "ollama:qwen3:8b"})

      assert state.conversation.model_chosen?
      state
    end

    test "/new returns to the placeholder, which is still nobody's choice" do
      fresh = keyless() |> switched_away() |> new()

      assert fresh.conversation.model == @placeholder
      refute fresh.conversation.model_chosen?
      assert fresh |> info({:error, @missing}) |> unwrapped() =~ "no provider key was found"
    end

    test "not when the start's provider was somebody's choice" do
      fresh = %{keyless() | selected: "anthropic"} |> switched_away() |> new()

      assert fresh.conversation.model_chosen?
    end

    # `--config none` starts on the placeholder beside a key it does not
    # look at; the line keeps naming the placeholder's provider there.
    test "not when a provider's key was set at the start" do
      setup =
        Map.update!(keyless(), :providers, fn [anthropic, openai | rest] ->
          [anthropic, %{openai | credential: :present} | rest]
        end)

      fresh = setup |> switched_away() |> new()

      assert fresh.conversation.model_chosen?
    end

    # The panel drops the setup once it switches the session
    # (`Lemieux.TUI.FirstRun.saved/3`): a key pasted there is one the
    # missing-key line must not deny.
    test "not once the panel has switched the session" do
      fresh = nil |> switched_away() |> new()

      assert fresh.conversation.model_chosen?
    end
  end

  # A transcript's model was chosen when that session began, and `/resume`
  # names its vendor, as `lmx --resume` does.
  test "/resume does not carry the mark" do
    state = unchosen_screen(@placeholder)
    resumed = fake_session(%{snapshot("03OLD") | model: @placeholder})

    state = put_in(state.resume.start, fn _id, _subscriber -> {:ok, resumed} end)
    state = command(state, "/resume 03OLD")

    assert_receive {:resume_result, _id, {:ok, _details, _sessions} = result}
    assert {:noreply, switched} = TUI.handle_info({:resume_result, "03OLD", result}, state)

    assert switched.id == "03OLD"
    assert switched.conversation.model_chosen?
  end
end
