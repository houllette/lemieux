defmodule Lemieux.TUI.FirstRunTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.Frame
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.TUI

  @caveat "set OLLAMA_CONTEXT_LENGTH to 32768 or more (65536 recommended)"

  defp providers do
    [
      %{
        id: "anthropic",
        label: "Anthropic",
        env: "ANTHROPIC_API_KEY",
        model: "anthropic:claude-sonnet-5"
      },
      %{id: "openai", label: "OpenAI", env: "OPENAI_API_KEY", model: "openai:gpt-6-sol"},
      %{
        id: "zai_coding_plan",
        label: "Z.AI Coding Plan",
        env: "ZAI_API_KEY",
        model: "zai_coding_plan:glm-5.3"
      }
    ]
  end

  defp local_row do
    %{
      id: "ollama",
      label: "Local (Ollama)",
      model: "ollama:qwen3:8b",
      env: nil,
      key?: false,
      note: "no key needed · #{@caveat} for the Ollama server"
    }
  end

  defp opened(first_run) do
    [id: "01FIRSTRUN", model: "test:model", test_mode: {80, 24}, first_run: first_run]
    |> TUI.new()
    |> sized()
    |> TUI.FirstRun.open()
  end

  defp panel(state) do
    state
    |> TUI.render(%Frame{width: 80, height: 24})
    |> Enum.find_value(fn
      {%Paragraph{block: %{title: " Choose a model provider "}} = panel, _area} -> panel
      _other -> nil
    end)
  end

  defp texts(%Paragraph{text: lines}),
    do: Enum.map(lines, fn line -> Enum.map_join(line.spans, & &1.content) end)

  describe "choosing a provider" do
    # Opening on the first row made Enter choose a vendor for somebody who
    # had not chosen one; the first row was whichever the host listed first.
    test "opens with no provider selected, and Enter alone asks for a choice" do
      state = opened(%{providers: providers(), config_path: "/tmp/lmx/config.json"})

      assert state.modal.index == nil
      refute Enum.any?(texts(panel(state)), &String.starts_with?(&1, "›"))

      asked = press(state, "enter")
      assert asked.modal.stage == :pick
      assert screen(asked) =~ "↑↓ to choose a provider first"

      assert press(state, "up").modal.index == 2

      assert state |> press("down") |> press("enter") |> Map.get(:modal) |> Map.get(:stage) ==
               :key
    end

    test "preselects the provider of a model the person named" do
      state = opened(%{providers: providers(), config_path: nil, selected: "openai"})

      assert state.modal.index == 1
      assert state |> press("enter") |> Map.get(:modal) |> Map.get(:stage) == :key
    end

    # Ratatui trims the leading spaces of wrapped lines, which pulled every
    # row but the selected one out of its column.
    test "every row keeps its column, selected or not" do
      state = opened(%{providers: providers(), config_path: nil}) |> press("down")
      %Paragraph{wrap: false} = panel = panel(state)

      # In characters, not bytes: the marker is one column and three bytes.
      columns =
        for text <- texts(panel),
            provider <- providers(),
            {offset, _length} <- [:binary.match(text, provider.model)],
            do: {text, text |> binary_part(0, offset) |> String.length()}

      assert length(columns) == length(providers())
      assert columns |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
      assert [{"› Anthropic" <> _, _} | _rest] = columns
    end

    test "the host's hint is shown under the list" do
      hint = "No key? lmx also runs local models with Ollama; #{@caveat} for the Ollama server."
      screen = opened(%{providers: providers(), config_path: nil, hint: hint}) |> screen()

      assert screen =~ "No model credentials were found"
      assert String.replace(screen, ~r/\s+/, " ") =~ @caveat
    end

    # Esc closed the panel and took the hint with it, so the first prompt's
    # missing-key error was the only thing left on screen, naming one vendor.
    test "the hint stays in the transcript once the panel is skipped" do
      hint = "No key? lmx also runs local models with Ollama; #{@caveat} for the Ollama server."

      skipped =
        opened(%{providers: providers(), config_path: nil, hint: hint}) |> press("esc")

      assert skipped.modal == nil
      text = skipped |> screen() |> String.replace(~r/\s+/, " ")
      assert text =~ "no key saved"
      assert text =~ "lmx also runs local models with Ollama"
      assert text =~ @caveat
    end

    # "No model credentials were found" was false under `--config none` with
    # another provider's key set; the host knows why the panel opened.
    test "the host's intro replaces the panel's own" do
      intro =
        "--config none starts on anthropic:claude-sonnet-5 and picks no model from your keys."

      screen =
        opened(%{providers: providers(), config_path: nil, intro: intro})
        |> screen()
        |> String.replace(~r/\s+/, " ")

      assert screen =~ intro
      refute screen =~ "No model credentials were found"
    end

    # Asking somebody to paste a key that is already set, for a provider
    # they could have used as it was.
    test "a provider whose key is set is marked, and switched to without asking for it" do
      keyed = %{
        id: "openai",
        label: "OpenAI",
        env: "OPENAI_API_KEY",
        model: "openai:gpt-6-sol",
        credential: :present
      }

      state = opened(%{providers: [hd(providers()), keyed], config_path: nil})
      assert screen(state) =~ "key set"

      chosen = state |> press("up") |> press("enter")
      assert chosen.modal == nil

      assert_receive {:first_run_saved, ^keyed, {:ok, false} = result}
      assert {:noreply, said} = TUI.handle_info({:first_run_saved, keyed, result}, chosen)

      text = said |> screen() |> String.replace(~r/\s+/, " ")
      assert text =~ "OpenAI · using openai:gpt-6-sol"
      refute text =~ "key set for this sitting"
    end
  end

  describe "the key" do
    test "is saved in plain text, said plainly, with the variable that would do instead" do
      state =
        opened(%{
          providers: providers(),
          config_path: Path.join(System.tmp_dir!(), "config.json")
        })
        |> press("down")
        |> press("enter")

      text = state |> screen() |> String.replace(~r/\s+/, " ")

      assert text =~ "Saved in plain text to"
      assert text =~ "config.json"
      assert text =~ "ANTHROPIC_API_KEY"

      unless match?({:win32, _}, :os.type()), do: assert(text =~ "readable only by you")
    end

    test "is used for the sitting only when there is no config file to save it in" do
      env = "LMX_FIRST_RUN_TEST_#{System.unique_integer([:positive])}"
      on_exit(fn -> System.delete_env(env) end)
      provider = %{id: "zz", label: "ZZ", env: env, model: "zz:model"}

      state =
        opened(%{providers: [provider], config_path: nil}) |> press("down") |> press("enter")

      assert screen(state) |> String.replace(~r/\s+/, " ") =~ "Used for this sitting only"

      state = state |> type("secret-key") |> press("enter")
      assert state.modal == nil
      assert_receive {:first_run_saved, ^provider, {:ok, false} = result}
      assert System.get_env(env) == "secret-key"

      assert {:noreply, said} = TUI.handle_info({:first_run_saved, provider, result}, state)
      assert screen(said) =~ "set for this sitting only"
    end
  end

  describe "a local row" do
    test "needs no key: choosing it switches the session and says what the window needs" do
      local = local_row()
      state = opened(%{providers: providers() ++ [local], config_path: "/tmp/lmx/config.json"})

      chosen = state |> press("up") |> press("enter")
      assert chosen.modal == nil

      assert_receive {:first_run_saved, ^local, {:ok, false} = result}
      assert {:noreply, said} = TUI.handle_info({:first_run_saved, local, result}, chosen)

      text = said |> screen() |> String.replace(~r/\s+/, " ")
      assert text =~ "using ollama:qwen3:8b"
      assert text =~ @caveat
      assert said.session_view.first_run == nil
    end
  end
end
