# The first state of a screen: host options read once, the harness filling in
# whatever the options left out, and the rows a sitting opens with.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Setup do
    @moduledoc "Builds a `Lemieux.TUI` state from host options and the session's harness."

    alias Lemieux.Conversation
    alias Lemieux.ModelSpec
    alias Lemieux.Session
    alias Lemieux.Tools
    alias Lemieux.TUI
    alias Lemieux.TUI.Callbacks
    alias Lemieux.TUI.CatalogState
    alias Lemieux.TUI.History
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Layout
    alias Lemieux.TUI.Links
    alias Lemieux.TUI.Notices
    alias Lemieux.TUI.Renderer
    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.Turn
    alias Lemieux.TUI.Updates

    @doc false
    @spec new(opts :: keyword()) :: TUI.t()
    def new(opts) do
      opts = with_harness(opts)
      transport = Keyword.get(opts, :transport, :local)
      # ExRatatui's headless test terminal: see `effect/4`.
      headless? = Keyword.has_key?(opts, :test_mode)
      # Both raise: a theme or a renderer that cannot be used came from a
      # host's code, and a screen that quietly started without it would hide
      # the mistake. The config file is checked before it gets this far.
      themes = Theme.registry!(Keyword.get(opts, :themes) || %{})
      renderers = Renderer.registry!(Keyword.get(opts, :renderers) || %{})

      %TUI{
        session: Keyword.get(opts, :session),
        id: Keyword.get(opts, :id),
        references: %{
          cwd: Keyword.get(opts, :cwd),
          mcp_config: Keyword.get(opts, :mcp_config),
          environment: Keyword.get(opts, :environment),
          directory: nil,
          entries: [],
          refreshed_at: nil,
          index: nil,
          fuzzy: nil,
          # The person's own settings file, where `/mcp add` saves a server
          # they keep for themselves. See `Lemieux.TUI.MCPInteraction`.
          config_path: Keyword.get(opts, :config_path)
        },
        conversation:
          Conversation.new(
            model: Keyword.get(opts, :model),
            commands: Keyword.get(opts, :commands) || []
          ),
        appearance: %{
          name: nil,
          colour: nil,
          theme: theme_option(Keyword.get(opts, :theme) || no_color_theme(opts), themes),
          themes: themes,
          no_color: no_color(opts)
        },
        input: ExRatatui.textarea_new(),
        tools: no_tools(systemone_setup(Keyword.get(opts, :harness))),
        terminal: %{
          width: 80,
          height: 20,
          cursor_blink: %{visible?: true, tick: nil},
          link_press: nil,
          feedback: nil,
          notices: Notices.new(),
          row_cache: nil,
          scroll_coalesce?: Keyword.get(opts, :scroll_coalesce?, false),
          scroll_pending: nil,
          open_link: Keyword.get(opts, :open_link, &Links.open/1),
          clipboard:
            effect(opts, :clipboard, headless?, fn -> Callbacks.clipboard(transport) end),
          # A no-op unless a host asks for it, like `:size`: writing an escape
          # sequence is an effect on a stream this module does not own.
          # `Lemieux.CLI.TUI` is the host that wants it.
          title: Keyword.get(opts, :title, &Callbacks.title/1),
          # The same rule for a notification: the terminal showing the screen
          # is the transport's, so the default speaks through it.
          notify: effect(opts, :notify, headless?, fn -> Callbacks.notify(transport) end),
          notifications?: Keyword.get(opts, :notifications, true) != false,
          # Handing the terminal to `$EDITOR` and back, and reading an image off
          # the clipboard, are effects on the local machine only; a transport
          # showing this screen elsewhere gets neither unless its host supplies
          # one. See `Lemieux.TUI.ExternalEditor` and `Lemieux.TUI.ImagePaste`.
          editor: effect(opts, :editor, headless?, fn -> Callbacks.editor(transport, opts) end),
          paste_image:
            effect(opts, :paste_image, headless?, fn -> Callbacks.paste_image(transport) end),
          repaint: 0
        },
        catalog: %{
          providers: Keyword.get(opts, :providers, []),
          models: Keyword.get(opts, :models, []),
          model_choices: [],
          model_tabs: [],
          model_tab_rows: 0,
          model_metadata: Keyword.get(opts, :model_metadata, %{}),
          preferred_models: Keyword.get(opts, :preferred_models, %{}),
          preferred_efforts: Keyword.get(opts, :preferred_efforts, %{}),
          model_now: Keyword.get(opts, :model_now),
          recent_models:
            opts
            |> Keyword.get(:sessions, [])
            |> Enum.map(& &1.model)
            |> Enum.filter(&is_binary/1),
          # Through `CatalogState.discover/3` below, as a late discovery
          # is, rather than as given.
          discovered: [],
          discover: Keyword.get(opts, :discover, %{}),
          efforts: Keyword.get(opts, :efforts, []),
          mcp: Keyword.get(opts, :mcp_servers, [])
        },
        skills: Keyword.get(opts, :skills, []),
        status: %{
          line: Keyword.get(opts, :status_line),
          compact_at: compact_at_option(opts),
          words: Keyword.get(opts, :processing),
          followups: Keyword.get(opts, :followups),
          renderers: renderers,
          keys: keys_option(Keyword.get(opts, :keys)),
          layout: layout_option(Keyword.get(opts, :layout)),
          update: Updates.new(Keyword.get(opts, :updates))
        },
        tool_choices: %{
          standard: Keyword.get(opts, :standard_tools, Tools.default()),
          statuses: Keyword.get(opts, :tool_statuses, []),
          command_policy: Keyword.get(opts, :command_policy),
          elixir: Keyword.get(opts, :elixir_decision, :allow),
          # Filled in when `/elixir` goes on; see `Lemieux.TUI.Choices`.
          delegation: nil,
          permissions: Keyword.get(opts, :permissions),
          checkpoints: Keyword.get(opts, :checkpoints)
        },
        resume: %{
          sessions: Keyword.get(opts, :sessions, []),
          list: Keyword.get(opts, :list_sessions),
          start: Keyword.get(opts, :resume_session),
          new: Keyword.get(opts, :new_session),
          busy?: false,
          initial_task: nil,
          startup_status: :idle,
          start_async: Keyword.get(opts, :start_async),
          task_supervisor: Keyword.get(opts, :task_supervisor),
          monitor: nil,
          down: nil
        },
        # nils are dropped rather than carried: a `feedback_store: nil` would
        # override the ledger the sessions directory names with nothing.
        feedback_opts:
          opts
          |> Keyword.take([:feedback_store, :sessions_dir, :feedback_dir, :actor])
          |> Enum.reject(fn {_key, value} -> is_nil(value) end),
        elixir_mode?: Keyword.get(opts, :elixir_mode?, false),
        turn: Turn.idle_turn(),
        clock: Keyword.get(opts, :clock, &Callbacks.clock/0),
        history:
          opts
          |> Keyword.get(:history_file)
          |> History.loaded()
          |> History.staged(Keyword.get(opts, :prompt)),
        session_view: %{
          mcp: %{},
          mcp_ready?: true,
          mcp_announced?: false,
          plan: nil,
          requests: 0,
          request_cap: Keyword.get(opts, :request_cap),
          sandbox: Keyword.get(opts, :sandbox),
          mcp_trust: Keyword.get(opts, :mcp_trust),
          first_run: Keyword.get(opts, :first_run),
          banner?: Keyword.has_key?(opts, :permissions) or Keyword.has_key?(opts, :sandbox),
          outputs: [],
          noticed: []
        }
      }
      |> discovered_models(Keyword.get(opts, :discovered_models) || [])
    end

    # The screen's opinions that a `Lemieux.Harness` carries, read from it
    # wherever the option itself was not given. `Map.get/2` rather than a
    # struct match per field, so a harness from a build that has not yet grown
    # one of these fields reads as "unset" rather than as a crash. Applied in
    # both `new/1` and `Lemieux.TUI.Lifecycle.mount/1`, because mounting reads
    # `:notices` before it builds the state.
    # `environment` too, because `!cmd`, `/diff` and `/undo` run through the
    # session's environment, where its credential policy and any sandbox apply.
    @harness_fields ~w(theme themes keys layout status_line followups processing skills notices
                       auto_compaction compact_at
                       renderers commands environment)a

    @doc false
    @spec with_harness(opts :: keyword()) :: keyword()
    def with_harness(opts) do
      case Keyword.get(opts, :harness) do
        nil ->
          opts

        %Lemieux.Harness{} = harness ->
          Enum.reduce(@harness_fields, opts, &from_harness(&2, harness, &1))

        other ->
          raise ArgumentError, "harness: expected a %Lemieux.Harness{}, got #{inspect(other)}"
      end
    end

    defp from_harness(opts, harness, field),
      do: Keyword.put_new_lazy(opts, field, fn -> Map.get(harness, field) end)

    @doc false
    @spec welcome(state :: TUI.t(), text :: String.t() | nil) :: TUI.t()
    def welcome(state, nil), do: state
    def welcome(state, text), do: %{state | lines: [{:lmx, text} | state.lines]}

    # Workspace and configuration notices, in the notice box. On standard
    # error a full-screen application covers them up, so the person saw them
    # on the way out — hours after the decision they were about. As
    # transcript rows they were seen, and then carried through the whole
    # sitting; see `Lemieux.TUI.Notices`.
    @doc false
    @spec notices(state :: TUI.t(), notices :: [String.t()] | nil) :: TUI.t()
    def notices(state, notices),
      do:
        Notices.say_all(
          state,
          :warning,
          List.wrap(notices) ++ colour_notice(state.appearance.no_color)
        )

    # An inherited `NO_COLOR` — from a desktop entry, or the shell of an
    # agent that set it for its own output — looks exactly like a terminal
    # that cannot draw colour, and nothing on the screen said which it was
    # (issue #4). The sentence names the variable and where to unset it,
    # and respects the choice: https://no-color.org is a convention `lmx`
    # keeps, so this only says it is in effect. The renderer (crossterm,
    # under `ExRatatui`) writes no colour at all while the variable is set,
    # so a theme named over it is drawn without its colours too; the second
    # sentence says so rather than letting the named theme look broken.
    defp colour_notice(nil), do: []

    defp colour_notice(:mono),
      do: [
        "NO_COLOR is set in the environment lmx started in, so the screen has no colour " <>
          "(theme mono). Unset it where lmx is launched for colour."
      ]

    defp colour_notice(:named),
      do: [
        "NO_COLOR is set in the environment lmx started in, so the terminal draws no colour " <>
          "whatever the theme. Unset it where lmx is launched for colour."
      ]

    # A terminal that is never resized never sends an event, so the size arrives as
    # an option: `ExRatatui.terminal_size/0` talks to the tty and hangs mounting
    # where there is none, which is every test in this suite. Measuring is an
    # effect, and `Lemieux.CLI.TUI` owns the effects.
    @doc false
    @spec sized(state :: TUI.t(), opts :: keyword()) :: TUI.t()
    def sized(state, opts) do
      case Keyword.get(opts, :size) do
        {width, height} when is_integer(width) and is_integer(height) ->
          put_in(state.terminal, %{state.terminal | width: max(width, 1), height: max(height, 1)})

        _unmeasured ->
          state
      end
    end

    # The empty in-flight tool state, keeping `systemone` — the one part a session
    # sets once, which a clear or a switch resets rather than drops.
    @doc false
    @spec no_tools(systemone :: map() | nil) :: TUI.in_flight()
    def no_tools(systemone),
      do: %{
        calls: %{},
        outputs: %{},
        approvals: %{},
        permissions: %{},
        question_flow: nil,
        mcp_flow: nil,
        deferred_steer: nil,
        sent_steers: [],
        systemone: systemone
      }

    @doc false
    @spec systemone_reset(systemone :: map() | nil) :: map() | nil
    def systemone_reset(nil), do: nil
    def systemone_reset(systemone), do: %{systemone | saved: nil, outcome: nil}

    defp systemone_setup(%Lemieux.Harness{applied: applied}) do
      case Enum.find(applied, &(&1["module"] == "LemieuxSystemOneCompaction")) do
        %{"options" => %{"enabled" => true, "mode" => mode}} ->
          %{mode: mode, saved: nil, outcome: nil}

        _other ->
          nil
      end
    end

    defp systemone_setup(_harness), do: nil

    defp compact_at_option(opts) do
      if Keyword.get(opts, :auto_compaction, true) == false do
        nil
      else
        case Keyword.get(opts, :compact_at, :default) do
          :default -> Session.default_compact_at()
          value -> value
        end
      end
    end

    # A name from the config file, a struct from an embedding host, or
    # nothing. An unknown name is the default rather than an error here:
    # `Lemieux.CLI.Config` refuses one at load, and a host that passes a bad
    # name gets a screen rather than no screen.
    defp theme_option(%Theme{} = theme, _themes), do: theme

    defp theme_option(name, themes) when is_binary(name) do
      case Theme.named(name, themes) do
        {:ok, theme} -> theme
        :error -> nil
      end
    end

    defp theme_option(_none, _themes), do: nil

    # https://no-color.org: a non-empty `NO_COLOR` asks for no colour, and a
    # theme somebody chose by name still wins over it — the convention is a
    # default, not a veto. `mono` is the shipped colourless theme. Read from
    # the options' `:env` when a test supplies one, the process otherwise.
    defp no_color_theme(opts) do
      env = Keyword.get_lazy(opts, :env, &System.get_env/0)

      case Map.get(env, "NO_COLOR") do
        value when is_binary(value) and value != "" -> "mono"
        _unset -> nil
      end
    end

    # What `NO_COLOR` did to this screen, for the startup notice
    # (`notices/2`) and `/theme`: `:mono` when it chose the theme, `:named`
    # when a theme chosen by name won but the terminal layer still draws no
    # colour while the variable is set, `nil` when it is unset.
    defp no_color(opts) do
      case {no_color_theme(opts), Keyword.get(opts, :theme)} do
        {nil, _theme} -> nil
        {"mono", nil} -> :mono
        {"mono", _named} -> :named
      end
    end

    # A module, a map in the form `Lemieux.TUI.Keys.from_map/1` reads, a table
    # already read, or nothing. The map raises for the reason the themes do:
    # it came from code, and a screen that quietly kept the shipped bindings
    # would hide the mistake. The config file is checked before it gets here.
    defp keys_option(nil), do: nil
    defp keys_option(%Keys{} = keys), do: keys
    defp keys_option(map) when is_map(map), do: Keys.from_map!(map)
    defp keys_option(module), do: implementing(module, :keys, Keys, {:action, 1})

    defp layout_option(nil), do: nil
    defp layout_option(module), do: implementing(module, :layout, Layout, {:panes, 2})

    # A module option that is not a module implementing the behaviour is the
    # same kind of mistake as a renderer that is not one, and is refused the
    # same way, at construction, rather than on the first key or the first
    # frame.
    defp implementing(module, option, behaviour, {name, arity}) do
      if is_atom(module) and Code.ensure_loaded?(module) and
           function_exported?(module, name, arity),
         do: module,
         else:
           raise(
             ArgumentError,
             "#{option}: #{inspect(module)} does not implement #{inspect(behaviour)}"
           )
    end

    # `:discovered_models` takes what a late discovery does — specs, and a
    # host's `{:preferred, spec}` — and goes the same way, so the order
    # `/provider` relies on is made once, in one place. Put in the catalog as
    # given, a `{:preferred, spec}` reached `ModelSpec.provider/1`, which
    # takes a string, at the first merge, and the screen crashed.
    defp discovered_models(state, discovered) do
      provider = ModelSpec.provider(state.conversation.model)
      %{state | catalog: CatalogState.discover(state.catalog, discovered, provider)}
    end

    # The local machine's effects are the clipboard write, a desktop
    # notification, the editor handoff and the clipboard image read. On
    # ExRatatui's headless test terminal they default to inert: nobody is
    # looking at that screen, so a live default would act on the terminal and
    # clipboard of whoever runs the tests. An explicitly passed callback still
    # wins. See `Lemieux.TUI.Callbacks.inert/1`.
    defp effect(opts, key, false = _headless?, live), do: Keyword.get_lazy(opts, key, live)
    defp effect(opts, key, true = _headless?, _live), do: Keyword.get(opts, key, inert(key))

    # `nil` is how the editor and image keys already say "not available here".
    defp inert(key) when key in [:editor, :paste_image], do: nil
    defp inert(_key), do: &Callbacks.inert/1
  end
end
