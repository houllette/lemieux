if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.FirstRun do
    @moduledoc """
    The first screen for somebody with no model credentials yet.

    A host that found no usable key passes `:first_run`:

        %{providers: [%{id: "openai", label: "OpenAI", env: "OPENAI_API_KEY",
                        model: "openai:gpt-6-sol", credential: :missing}, ...],
          config_path: "~/.lmx/config.json",
          selected: nil,
          intro: nil,
          hint: "No key? ..."}

    and instead of a first prompt that fails with a paragraph about
    environment variables, the screen opens on a choice: pick a provider,
    paste its key (drawn masked), and it is saved and the session switches to
    that provider's model — unless the row is marked `own?: true`, the model
    the person chose themselves, which the session is already on: then only
    the key is saved. A row with `key?: false` — a model served on this
    machine — needs no key, and neither does one whose `credential` is
    `:present` (the host found its key already set, which happens when the
    person named another provider's model, or under `--config none`):
    choosing either switches the session at once, saving nothing. Esc skips
    it, saying that no key was saved and how to add one, naming the
    `/provider` switch to each row that needs no key, and leaving the host's
    hint in the transcript.

    No row is selected until the person moves to one, unless the host names
    one in `:selected` (the provider of a model the person chose
    themselves). Opening on the first row made Enter pick a vendor for
    somebody who had not chosen one, and the first row was whichever vendor
    the host happened to list first. `:hint` is the host's sentence for
    under the list — `lmx` says there how to run a model locally, and what
    that needs — and `:intro`, when given, replaces the panel's first
    sentence, which says no credentials were found: the host knows when that
    is not why the panel opened.

    Saving is the host's: `Lemieux.CLI.Config.put_provider_key/3` and
    `put_model/2` when the CLI provides them, called by name so this screen
    does not need the CLI to compile, and only when there is a
    `:config_path` to save to. The key is also put in this process's
    environment under the provider's variable, which is what the provider
    reads it from for the rest of the sitting — saved or not.
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Clear
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.Session
    alias Lemieux.TUI
    alias Lemieux.TUI.History
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Modal
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Transcript
    alias Lemieux.TUI.Window

    @intro "No model credentials were found. Pick a provider and paste its API key " <>
             "(requests are billed by that provider), or Esc to look around first."

    # The staged queue waits until the panel is answered — skipped, or a
    # provider switched to — so a prompt staged before the session was up
    # goes to the model chosen here (`Lemieux.TUI.History.hold/2`).
    @doc false
    @spec open(TUI.t()) :: TUI.t()
    def open(%TUI{session_view: %{first_run: %{providers: [_ | _]} = setup}, modal: nil} = state) do
      index = preselected(setup.providers, setup[:selected])

      History.hold(
        %{state | modal: %{kind: :first_run, stage: :pick, index: index, key: "", error: nil}},
        :first_run
      )
    end

    def open(state), do: state

    defp preselected(_providers, nil), do: nil
    defp preselected(providers, id), do: Enum.find_index(providers, &(Map.get(&1, :id) == id))

    @doc false
    @spec key(ExRatatui.Event.Key.t(), TUI.t()) :: {:noreply, TUI.t()}
    def key(event, %TUI{modal: %{stage: :pick}} = state) do
      providers = providers(state)

      case {event.code, Keys.action(state.status.keys, event)} do
        {_code, :previous} -> {:noreply, pick(state, -1, providers)}
        {_code, :next} -> {:noreply, pick(state, 1, providers)}
        {_code, :submit} -> {:noreply, chosen(state, selected(providers, state.modal.index))}
        {_code, action} when action in [:dismiss, :interrupt] -> {:noreply, skip(state)}
        _other -> {:noreply, state}
      end
    end

    def key(%ExRatatui.Event.Key{code: code, modifiers: modifiers} = event, state) do
      case {code, Keys.action(state.status.keys, event)} do
        {_code, :submit} ->
          {:noreply, save(state)}

        {_code, :dismiss} ->
          {:noreply, %{state | modal: %{state.modal | stage: :pick, key: "", error: nil}}}

        {_code, :interrupt} ->
          {:noreply, skip(state)}

        {"backspace", _action} ->
          {:noreply, update_key(state, &String.slice(&1, 0, max(String.length(&1) - 1, 0)))}

        {character, _action} ->
          {:noreply, typed(state, character, modifiers)}
      end
    end

    @doc false
    @spec paste(ExRatatui.Event.Paste.t(), TUI.t()) :: {:noreply, TUI.t()}
    def paste(%ExRatatui.Event.Paste{content: content}, %TUI{modal: %{stage: :key}} = state)
        when is_binary(content),
        do: {:noreply, update_key(state, &(&1 <> String.trim(content)))}

    def paste(_event, state), do: {:noreply, state}

    @doc false
    @spec saved(TUI.t(), map(), term()) :: TUI.t()
    def saved(state, provider, {:ok, saved?}) do
      sentence = said(provider, saved?, state.session_view.first_run[:config_path])
      state = put_in(state.session_view.first_run, nil)

      state
      |> Transcript.say(:lmx, sentence)
      |> History.answered(:first_run)
    end

    # The switch failed, and the panel is closed: what is staged goes as it
    # would have without the panel, and says the same thing a first prompt
    # would. It stays in the up-arrow history to send again after `/model`.
    def saved(state, provider, {:error, reason}),
      do:
        state
        |> Transcript.say(
          :notice,
          "could not switch to #{provider.model}: #{inspect(reason)}; /model picks another"
        )
        |> History.answered(:first_run)

    # A row needing nothing pasted — a model served on this machine, or a
    # provider whose key the host found already set — saved nothing.
    defp said(%{key?: false} = provider, _saved?, _path), do: switched(provider)
    defp said(%{credential: :present} = provider, _saved?, _path), do: switched(provider)

    defp said(provider, saved?, path),
      do: "#{provider.label} key #{where_saved(saved?, path)} · using #{provider.model}"

    defp switched(provider) do
      [provider.label, "using #{provider.model}", provider[:note]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
    end

    defp where_saved(true, path), do: "saved to #{path}"

    defp where_saved(false, nil),
      do: "set for this sitting only (there is no config file to save it in)"

    defp where_saved(false, _path), do: "set for this sitting (the host could not save it)"

    defp providers(state), do: state.session_view.first_run.providers

    defp selected(_providers, nil), do: nil
    defp selected(providers, index), do: Enum.at(providers, index)

    # From nothing selected, down is the first row and up the last.
    defp pick(%TUI{modal: %{index: nil}} = state, by, providers),
      do: select(state, if(by > 0, do: 0, else: length(providers) - 1))

    defp pick(state, by, providers),
      do: select(state, Integer.mod(state.modal.index + by, length(providers)))

    defp select(state, index), do: %{state | modal: %{state.modal | index: index, error: nil}}

    defp chosen(state, nil), do: put_in(state.modal.error, "↑↓ to choose a provider first")
    defp chosen(state, %{key?: false} = provider), do: switch(state, provider)
    defp chosen(state, %{credential: :present} = provider), do: switch(state, provider)
    defp chosen(state, _provider), do: put_in(state.modal.stage, :key)

    defp switch(state, provider) do
      session = state.session
      app = self()

      Task.start(fn ->
        send(app, {:first_run_saved, provider, unsaved(provider, session)})
      end)

      Modal.close(state)
    end

    defp typed(state, character, modifiers) do
      if String.length(character) == 1 and not Enum.any?(modifiers, &(&1 in ["ctrl", "alt"])),
        do: update_key(state, &(&1 <> character)),
        else: state
    end

    defp update_key(state, change),
      do: %{state | modal: %{state.modal | key: change.(state.modal.key), error: nil}}

    # The host's hint outlives the panel: closing it used to take the one
    # mention of a keyless way to start with it, leaving the first prompt's
    # missing-key error, about the placeholder's provider, as the only advice
    # on screen.
    defp skip(state) do
      setup = state.session_view.first_run

      state
      |> Modal.close()
      |> Transcript.say(:lmx, skipped(setup[:providers] || []))
      |> said_again(setup[:hint])
      |> History.answered(:first_run)
    end

    # It said "/provider and /model choose one later", and neither does: a
    # key cannot be added inside a sitting once this panel is closed,
    # `/provider` saves none, and in a keyless start no provider has a key
    # to switch to. A key is set in the environment, or pasted here when the
    # panel opens at the next start. What does work now is a row needing no
    # key — a model served on this machine, a provider whose key is set —
    # and each is named with the `/provider` that switches to it.
    defp skipped(providers) do
      ready =
        for %{id: id} = row <- providers,
            row[:key?] == false or row[:credential] == :present,
            do: "/provider " <> id

      now = if ready == [], do: "", else: " · #{Enum.join(ready, " or ")} works now"
      "no key saved · set one in your environment, or paste it here at the next start" <> now
    end

    defp said_again(state, hint) when is_binary(hint), do: Transcript.say(state, :lmx, hint)
    defp said_again(state, _no_hint), do: state

    defp save(%TUI{modal: %{key: ""}} = state),
      do: put_in(state.modal.error, "paste or type the key first")

    defp save(state) do
      provider = Enum.at(providers(state), state.modal.index)
      key = String.trim(state.modal.key)
      config_path = state.session_view.first_run.config_path
      session = state.session
      app = self()

      Task.start(fn ->
        send(app, {:first_run_saved, provider, store(provider, key, config_path, session)})
      end)

      Modal.close(state)
    end

    # The key reaches the provider through its environment variable for this
    # sitting whatever the host can save, so a host without the save
    # functions, or without a file to save to, still leaves a working session
    # behind.
    #
    # A row marked `own?` carries the model the person chose — named, or the
    # one a resumed session's transcript recorded — which the session is
    # already on. Only its key is missing, so only the key is saved: writing
    # the row's model as the one to start on, or switching to it, would at
    # best repeat the person's choice and at worst, as when the row carried
    # the table's model, overwrite it.
    defp store(provider, key, config_path, session) do
      if is_binary(provider[:env]), do: System.put_env(provider.env, key)
      config = Lemieux.CLI.Config

      saved? =
        is_binary(config_path) and
          host_save(config, :put_provider_key, [config_path, provider.id, key]) and
          (own?(provider) or host_save(config, :put_model, [config_path, provider.model]))

      if own?(provider),
        do: {:ok, saved?},
        else: with({:ok, _model} <- set_model(session, provider.model), do: {:ok, saved?})
    end

    defp own?(provider), do: Map.get(provider, :own?, false)

    # A row with nothing pasted is a choice for this sitting only. Saving a
    # local model as the one new sessions start with would outrank a key
    # the person sets tomorrow, and the host finds a served model, or the
    # provider whose key is set, again on the next start.
    defp unsaved(provider, session) do
      with {:ok, _model} <- set_model(session, provider.model), do: {:ok, false}
    end

    defp host_save(module, function, args) do
      Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) and
        apply(module, function, args) in [:ok, true]
    end

    defp set_model(nil, model), do: {:ok, model}
    defp set_model(session, model), do: Session.set_model(session, model)

    @doc false
    @spec render(TUI.t(), map()) :: [{term(), Rect.t()}]
    def render(state, panes) do
      theme = Screen.theme(state)
      muted = %Style{fg: theme.text.muted}
      # The border and the padding take two columns on each side.
      width = max(panes.input.width - 4, 10)

      lines =
        case state.modal.stage do
          :pick -> pick_lines(state, theme, muted, width)
          :key -> key_lines(state, theme, muted, width)
        end

      bottom = panes.input.y + panes.input.height
      height = min(length(lines) + 4, max(bottom - panes.transcript.y, 6))
      area = %Rect{x: panes.input.x, y: bottom - height, width: panes.input.width, height: height}

      # Not wrapped by the widget: ratatui trims the leading spaces of
      # wrapped lines, which pulled every row but the selected one out of
      # its column. Prose is wrapped here instead, to the inner width.
      panel = %Paragraph{
        text: lines,
        wrap: false,
        block: %Block{
          title: " Choose a model provider ",
          titles: [
            %Block.Title{content: hint(state.modal.stage), position: :bottom, alignment: :right}
          ],
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: Screen.accent(state)},
          padding: {1, 1, 0, 0}
        }
      }

      [{%Clear{}, area}, {panel, area}]
    end

    defp hint(:pick), do: " ↑↓ choose · Enter next · Esc skip "
    defp hint(:key), do: " paste the key · Enter save · Esc back "

    defp pick_lines(state, theme, muted, width) do
      providers = providers(state)
      label_width = providers |> Enum.map(&String.length(&1.label)) |> Enum.max(fn -> 0 end)

      rows =
        providers
        |> Enum.with_index()
        |> Enum.map(fn {provider, index} ->
          selected? = index == state.modal.index

          style =
            if selected?,
              do: %Style{fg: Screen.accent(state), modifiers: [:bold]},
              else: %Style{fg: theme.text.plain}

          Line.new([
            Span.new(if(selected?, do: "› ", else: "  "), style: style),
            Span.new(String.pad_trailing(provider.label, label_width), style: style),
            Span.new("  #{provider.model}#{key_set(provider)}", style: muted)
          ])
        end)

      prose(state.session_view.first_run[:intro] || @intro, width, muted) ++
        [Line.new([]) | rows] ++
        below(state.session_view.first_run[:hint], width, muted) ++
        error_lines(state, theme, width)
    end

    defp key_lines(state, theme, muted, width) do
      provider = Enum.at(providers(state), state.modal.index)
      masked = String.duplicate("•", min(String.length(state.modal.key), 48))

      [
        Line.new([
          Span.new("#{provider.label} API key",
            style: %Style{fg: theme.text.plain, modifiers: [:bold]}
          )
        ])
      ] ++
        prose(where(provider, state.session_view.first_run.config_path), width, muted) ++
        [
          Line.new([]),
          Line.new([
            Span.new("key: "),
            Span.new(masked <> "▏", style: %Style{fg: Screen.accent(state)})
          ])
        ] ++ error_lines(state, theme, width)
    end

    # Where the key goes, said plainly: `Lemieux.CLI.Config` writes it into
    # the config file as text, and makes that file private (0600) — which is
    # only what "readable only by you" means where file modes do, so Windows
    # is not promised it.
    defp where(provider, nil) do
      "Used for this sitting only: there is no config file to save it in. " <>
        "Set #{variable(provider)} to keep it."
    end

    defp where(provider, config_path) do
      "Saved in plain text to #{home_relative(config_path)}#{private()}. " <>
        "Prefer an environment variable? Esc, and set #{variable(provider)} instead."
    end

    defp variable(provider), do: provider[:env] || "the provider's key variable"

    defp key_set(%{credential: :present}), do: " · key set"
    defp key_set(_provider), do: ""

    defp private do
      case :os.type() do
        {:win32, _name} -> ""
        _unix -> ", readable only by you"
      end
    end

    defp home_relative(path) do
      home = System.user_home()

      if is_binary(home) and home != "" and String.starts_with?(path, home <> "/"),
        do: "~" <> String.replace_prefix(path, home, ""),
        else: path
    end

    defp below(nil, _width, _style), do: []
    defp below(text, width, style), do: [Line.new([]) | prose(text, width, style)]

    defp error_lines(%TUI{modal: %{error: nil}}, _theme, _width), do: []

    defp error_lines(state, theme, width),
      do: [Line.new([]) | prose(state.modal.error, width, %Style{fg: theme.voices.notice})]

    defp prose(text, width, style),
      do: text |> Window.wrap(width) |> Enum.map(&Line.new([Span.new(&1, style: style)]))
  end
end
