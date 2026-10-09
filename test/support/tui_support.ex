defmodule Lemieux.TUI.TestSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias ExRatatui.CellSession
  alias ExRatatui.Event.Key
  alias ExRatatui.Event.Mouse
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.List
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Textarea
  alias Lemieux.Context
  alias Lemieux.TUI
  alias Lemieux.TUI.Theme

  @spec command(state :: TUI.t(), line :: String.t()) :: TUI.t()
  def command(state, line), do: state |> type(line) |> press("enter")

  @spec sepia() :: map()
  def sepia do
    Theme.dark()
    |> Theme.to_map()
    |> Map.put("name", "sepia")
    |> Map.put("accent", "#c08040")
  end

  @spec events(state :: TUI.t(), events :: [{String.t(), integer(), integer()}]) :: TUI.t()
  def events(state, events) do
    Enum.reduce(events, state, fn {kind, x, y}, state ->
      assert {:noreply, state} =
               TUI.handle_event(%Mouse{kind: kind, button: "left", x: x, y: y}, state)

      state
    end)
  end

  @spec said(count :: non_neg_integer()) :: [{:lmx, String.t()}]
  def said(n), do: for(i <- 1..n, do: {:lmx, "line #{i}"})

  @spec info(state :: TUI.t(), event :: term()) :: TUI.t()
  def info(state, event) do
    assert {:noreply, state} = TUI.handle_info({:lemieux, state.id, event}, state)
    state
  end

  @frame %Frame{width: 80, height: 24}

  @spec app_label() :: String.t()
  def app_label, do: "lemieux (v#{Lemieux.version()})"

  @spec screen(state :: TUI.t()) :: String.t()
  def screen(state) do
    state
    |> TUI.render(@frame)
    |> Enum.map_join("\n", fn
      {%Paragraph{text: text, block: block}, _rect} ->
        "#{titles(block)}\n#{rendered_text(text)}"

      {%Textarea{state: ref, block: block}, _rect} ->
        "#{titles(block)}\n#{ExRatatui.textarea_get_value(ref)}"

      {_widget, _rect} ->
        ""
    end)
  end

  @doc "The visible inline notice box's body, projected from the transcript widget, or `nil`."
  @spec notice_box(state :: TUI.t()) :: {Paragraph.t(), term()} | nil
  def notice_box(state) do
    state
    |> TUI.render(@frame)
    |> Enum.find_value(fn
      {%Paragraph{text: lines} = paragraph, rect} when is_list(lines) ->
        case Enum.drop_while(lines, &(not String.starts_with?(line_text(&1), "╭─ lmx"))) do
          [_header | body] ->
            body =
              body
              |> Enum.take_while(&(not String.starts_with?(line_text(&1), "╰")))
              |> Enum.map(&%{&1 | spans: &1.spans |> Enum.drop(1) |> Enum.drop(-1)})

            {%{paragraph | text: body}, rect}

          [] ->
            nil
        end

      _widget ->
        nil
    end)
  end

  defp line_text(line), do: Enum.map_join(line.spans, & &1.content)

  # A block carries a main title and any number of extra ones placed around
  # the border. Reading only the first would make the scrollback marker
  # invisible to every test here.
  defp titles(nil), do: ""

  defp titles(block),
    do:
      Enum.map_join([block.title | Enum.map(block.titles || [], & &1.content)], " ", &to_string/1)

  defp rendered_text(text) when is_binary(text), do: text

  defp rendered_text(lines) when is_list(lines) do
    Enum.map_join(lines, "\n", fn line -> Enum.map_join(line.spans, & &1.content) end)
  end

  # What a terminal does when it opens, and what `mount/1` asks for when it
  # can. Without it the paging keys work from the struct's default size while
  # the frame is a different one, and every assertion about how far a page
  # goes is measuring the mismatch.
  @spec sized(state :: TUI.t()) :: TUI.t()
  def sized(state),
    do: put_in(state.terminal, %{state.terminal | width: @frame.width, height: @frame.height})

  @spec key(code :: String.t(), modifiers :: [String.t()]) :: Key.t()
  def key(code, modifiers \\ []),
    do: %Key{code: code, kind: "press", modifiers: modifiers}

  @spec press(state :: TUI.t(), code :: String.t(), modifiers :: [String.t()]) :: TUI.t()
  def press(state, code, modifiers \\ []) do
    assert {:noreply, state} = TUI.handle_event(key(code, modifiers), state)

    state
  end

  # What is in the input box. The box is the library's editor widget, so this
  # reads through the reference rather than out of the struct.
  @spec typed(state :: TUI.t()) :: String.t()
  def typed(state), do: ExRatatui.textarea_get_value(state.input)

  # The row between the transcript and the input box, on its own: the only
  # widget in the frame that is a paragraph without a block around it.
  @spec status_row(state :: TUI.t()) :: term()
  def status_row(state) do
    state
    |> TUI.render(@frame)
    |> Enum.find_value(fn
      {%Paragraph{block: nil, text: text}, _rect} -> text
      _other -> nil
    end)
  end

  # The screen with its soft wraps taken back out. The live row wraps like any
  # other transcript row, and a phase long enough to need two of them is still
  # one sentence to assert on.
  @spec unwrapped(state :: TUI.t()) :: String.t()
  def unwrapped(state), do: state |> screen() |> String.replace(~r/\s+/, " ")

  # The grey text the empty box offers is drawn over the textarea's cursor
  # cell, so its first letter has the same column as typed text.
  @spec hint(state :: TUI.t()) :: String.t() | nil
  def hint(state) do
    state
    |> TUI.render(@frame)
    |> Enum.find_value(fn
      {%Paragraph{wrap: true, text: lines}, _rect} -> rendered_text(lines)
      _other -> nil
    end)
  end

  # Where the cursor is, as `{row, column}`.
  @spec caret(state :: TUI.t()) :: {non_neg_integer(), non_neg_integer()}
  def caret(state), do: ExRatatui.textarea_cursor(state.input)

  @spec painted_cursor(state :: TUI.t()) :: term()
  def painted_cursor(state) do
    widgets = TUI.render(state, @frame)
    {%Textarea{}, rect} = Enum.at(widgets, 2)
    {row, col} = caret(state)
    session = CellSession.new(@frame.width, @frame.height)
    :ok = CellSession.draw(session, widgets)
    snapshot = CellSession.take_cells(session)
    :ok = CellSession.close(session)

    Enum.find(snapshot.cells, &(&1.row == rect.y + row + 1 and &1.col == rect.x + col + 1))
  end

  @spec type(state :: TUI.t(), text :: String.t()) :: TUI.t()
  def type(state, text),
    do: text |> String.graphemes() |> Enum.reduce(state, &press(&2, &1))

  # Folds the session's own events back into the screen until the turn ends,
  # which is what the running app does with them. Without it the conversation
  # stays busy and every command is refused.
  @spec settle(state :: TUI.t(), deadline :: non_neg_integer()) :: TUI.t()
  def settle(state, deadline \\ 2_000)
  def settle(%{conversation: %{busy?: false}} = state, _deadline), do: state

  def settle(state, deadline) do
    receive do
      {:lemieux, _id, _event} = event ->
        {:noreply, next} = TUI.handle_info(event, state)
        settle(next, deadline)
    after
      deadline -> flunk("the turn never finished")
    end
  end

  @spec tui(fields :: keyword()) :: TUI.t()
  def tui(fields \\ []) do
    # Everything `TUI.new/1` already knows how to place, handed to it rather
    # than written over the struct afterwards. The completion menus' lists
    # are in that group because they live in one `:catalog` map, and a test
    # writing the map directly would have to restate the keys it does not
    # care about.
    # A state built here is never drawn on a terminal anybody watches, so it
    # is built the way ExRatatui's headless `test_mode` builds one: the
    # clipboard, notification, editor and image-paste defaults are inert
    # rather than acting on the machine running the suite.
    fields = Keyword.put_new(fields, :test_mode, {80, 24})

    {start_opts, state_fields} =
      Keyword.split(fields, [
        :test_mode,
        :notify,
        :editor,
        :paste_image,
        :standard_tools,
        :tool_statuses,
        :command_policy,
        :elixir_decision,
        :clipboard,
        :open_link,
        :title,
        :cwd,
        :mcp_config,
        :environment,
        :providers,
        :models,
        :model_metadata,
        :model_now,
        :preferred_models,
        :preferred_efforts,
        :discovered_models,
        :efforts,
        :mcp_servers,
        :sessions,
        :list_sessions,
        :resume_session,
        :new_session,
        :theme,
        :themes,
        :processing,
        :status_line,
        :followups,
        :renderers,
        :commands,
        :harness,
        :keys,
        :layout,
        :scroll_coalesce?
      ])

    state_fields = Keyword.update(state_fields, :lines, [], &Enum.reverse/1)

    # `:started_at` and `:frame` name the turn's own fields rather than the
    # struct's: they live inside one `:turn` map, and a test that wrote the
    # whole map would have to restate every other key in it.
    {turn_fields, state_fields} = Keyword.split(state_fields, [:started_at, :frame])

    # `history: ["what was typed"]` reads better in a test than the struct's
    # `%{entries: …, index: …, draft: …}`, so the helper builds the unit.
    state_fields =
      Keyword.replace_lazy(state_fields, :history, fn
        entries when is_list(entries) ->
          %{
            entries: entries,
            index: nil,
            draft: nil,
            queued: [],
            queued_selected: 1,
            revising: nil,
            revising_original: nil
          }

        history ->
          history
      end)

    state =
      [id: "01SESSION", model: "test:model"]
      |> Keyword.merge(start_opts)
      |> TUI.new()
      |> struct!(state_fields)

    %{state | turn: Enum.into(turn_fields, state.turn)}
  end

  @spec suggestions(state :: TUI.t()) :: term()
  def suggestions(state) do
    state
    |> TUI.render(@frame)
    |> Enum.find_value(fn
      {%List{} = list, _rect} -> list
      _other -> nil
    end)
  end

  # What the menu actually paints, as opposed to what it holds: the widget
  # carries every match, and the rect decides how many of them a person can
  # see at once.
  @spec suggestion_rect(state :: TUI.t()) :: term()
  def suggestion_rect(state) do
    state
    |> TUI.render(@frame)
    |> Enum.find_value(fn
      {%List{}, rect} -> rect
      _other -> nil
    end)
  end

  @spec painted_row(state :: TUI.t(), row :: integer()) :: String.t()
  def painted_row(state, row) do
    session = CellSession.new(@frame.width, @frame.height)
    :ok = CellSession.draw(session, TUI.render(state, @frame))
    cells = CellSession.take_cells(session).cells
    :ok = CellSession.close(session)

    cells
    |> Enum.filter(&(&1.row == row))
    |> Enum.sort_by(& &1.col)
    |> Enum.map_join(& &1.symbol)
  end

  @spec snapshot(id :: String.t(), entries :: [term()]) :: map()
  def snapshot(id, entries \\ []) do
    %{
      id: id,
      status: :idle,
      model: "test:model",
      provider: "test",
      reasoning_effort: "default",
      reasoning_efforts: ["default", "high"],
      cwd: File.cwd!(),
      pending: [],
      entries: entries,
      context: %Context{}
    }
  end

  @spec fake_session(snapshot :: map(), choices :: keyword()) :: pid()
  def fake_session(snapshot, choices \\ []) do
    owner = self()

    pid =
      spawn(fn ->
        fake_session_loop(%{
          owner: owner,
          snapshot: snapshot,
          providers: Keyword.get(choices, :providers, ["test", "openai"]),
          models: Keyword.get(choices, :models, ["test:model", "test:other"]),
          model_metadata: Keyword.get(choices, :model_metadata, %{}),
          efforts: Keyword.get(choices, :efforts, ["default", "high"]),
          tool_statuses:
            Keyword.get(choices, :tool_statuses, [
              %{name: "read", source: :local, enabled?: true},
              %{name: "bash", source: :local, enabled?: true}
            ]),
          mcp_statuses: Keyword.get(choices, :mcp_statuses, []),
          refresh: Keyword.get(choices, :refresh, {:ok, 0}),
          compact_result: Keyword.get(choices, :compact_result, {:error, :nothing_to_do}),
          steers: [],
          unavailable_providers: Keyword.get(choices, :unavailable_providers, []),
          elixir_decision: Keyword.get(choices, :elixir_decision, :allow)
        })
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  # The shape `Lemieux.Session.handle_call(:info, …)` replies with, taken from
  # the stand-in's snapshot and choices. `ready?` is true: a stand-in has no
  # MCP servers still connecting, so the screen reads the catalog it answers.
  defp fake_info(state) do
    snapshot = state.snapshot

    %{
      id: snapshot.id,
      status: Map.get(snapshot, :status, :idle),
      model: snapshot.model,
      provider: Map.get(snapshot, :provider),
      reasoning_effort: Map.get(snapshot, :reasoning_effort, "default"),
      reasoning_efforts: state.efforts,
      tools: for(%{source: :local, name: name} <- state.tool_statuses, do: name),
      cwd: Map.get(snapshot, :cwd),
      pending: Map.get(snapshot, :pending, []),
      queued_steers: Enum.reverse(state.steers),
      queued_follow_ups: [],
      request_id: nil,
      requests: 0,
      max_requests: nil,
      spent_usd: nil,
      max_cost_usd: nil,
      usage: %{},
      context: Map.get(snapshot, :context),
      context_window_known?: true,
      ready?: true,
      mcp: state.mcp_statuses
    }
  end

  defp fake_session_loop(state) do
    receive do
      {:"$gen_call", from, :snapshot} ->
        GenServer.reply(from, state.snapshot)
        fake_session_loop(state)

      # `Lemieux.Session.info/2`, the entries-free summary the screen reads at
      # startup. A stand-in that did not answer it made the screen ask whether
      # its session was a real one before asking it anything.
      {:"$gen_call", from, :info} ->
        GenServer.reply(from, fake_info(state))
        fake_session_loop(state)

      # `Lemieux.Session.mcp_clients/2`, which the `@` picker's resource
      # listing asks. A stand-in has no MCP servers; answering keeps that
      # listing from waiting out a call timeout behind a test.
      {:"$gen_call", from, :mcp_clients} ->
        GenServer.reply(from, [])
        fake_session_loop(state)

      {:"$gen_call", from, {:prompt, text, _contexts}} ->
        send(state.owner, {:prompted, text})
        GenServer.reply(from, :ok)
        fake_session_loop(state)

      {:"$gen_call", from, {:steer, text}} ->
        send(state.owner, {:steered, text})
        GenServer.reply(from, :ok)
        fake_session_loop(%{state | steers: [text | state.steers]})

      {:"$gen_call", from, {:revoke_steer, text}} ->
        remaining = Elixir.List.delete(state.steers, text)
        result = if remaining == state.steers, do: {:error, :already_sent}, else: :ok
        GenServer.reply(from, result)
        fake_session_loop(%{state | steers: remaining})

      {:"$gen_call", from, :available_providers} ->
        GenServer.reply(from, state.providers)
        fake_session_loop(state)

      {:"$gen_call", from, :available_models} ->
        GenServer.reply(from, state.models)
        fake_session_loop(state)

      {:"$gen_call", from, :model_metadata} ->
        GenServer.reply(from, state.model_metadata)
        fake_session_loop(state)

      {:"$gen_call", from, {:available_models, _provider}} ->
        GenServer.reply(from, state.models)
        fake_session_loop(state)

      {:"$gen_call", from, :reasoning_efforts} ->
        GenServer.reply(from, state.efforts)
        fake_session_loop(state)

      {:"$gen_call", from, {:tool_decision, _tool}} ->
        GenServer.reply(from, state.elixir_decision)
        fake_session_loop(state)

      # What `/elixir` reads before swapping the catalog, so that toggling the
      # mode off can put back a `delegate` the host never handed in.
      {:"$gen_call", from, :tools} ->
        GenServer.reply(from, Map.get(state, :tools, []))
        fake_session_loop(state)

      {:"$gen_call", from, {:set_provider, provider}} ->
        send(state.owner, {:set_provider, provider})

        reply =
          if provider in state.unavailable_providers,
            do: {:error, {:provider_unavailable, provider}},
            else: {:ok, "#{provider}:model"}

        GenServer.reply(from, reply)
        fake_session_loop(state)

      {:"$gen_call", from, {:set_model, model}} ->
        send(state.owner, {:set_model, model})
        GenServer.reply(from, {:ok, model})
        fake_session_loop(state)

      {:"$gen_call", from, {:set_reasoning_effort, effort}} ->
        send(state.owner, {:set_reasoning_effort, effort})
        GenServer.reply(from, {:ok, effort})
        fake_session_loop(state)

      {:"$gen_call", from, {:set_tools, tools}} ->
        names = Enum.map(tools, &Lemieux.Tool.name/1)
        send(state.owner, {:set_tools, names})
        GenServer.reply(from, {:ok, names})
        fake_session_loop(state)

      {:"$gen_call", from, :tool_status} ->
        GenServer.reply(from, state.tool_statuses)
        fake_session_loop(state)

      {:"$gen_call", from, :mcp_status} ->
        GenServer.reply(from, state.mcp_statuses)
        fake_session_loop(state)

      {:"$gen_call", from, {:reconnect_mcp, name}} ->
        send(state.owner, {:reconnected_mcp, name})
        GenServer.reply(from, :ok)
        fake_session_loop(state)

      {:"$gen_call", from, {:set_mcp_enabled, name, enabled?}} ->
        send(state.owner, {:mcp_enabled, name, enabled?})

        statuses =
          Enum.map(state.mcp_statuses, fn
            %{name: ^name} = status -> Map.put(status, :enabled?, enabled?)
            status -> status
          end)

        GenServer.reply(from, :ok)
        fake_session_loop(%{state | mcp_statuses: statuses})

      {:"$gen_call", from, {:add_mcp_servers, servers}} ->
        send(state.owner, {:added_mcp, servers})

        statuses =
          Enum.map(servers, fn server ->
            %{
              name: server["name"],
              transport: server["transport"],
              tool_count: 0,
              enabled?: true,
              error: "the server offered no tools"
            }
          end)

        GenServer.reply(from, :ok)
        fake_session_loop(%{state | mcp_statuses: state.mcp_statuses ++ statuses})

      {:"$gen_call", from, {:remove_mcp_server, name}} ->
        send(state.owner, {:removed_mcp, name})
        GenServer.reply(from, :ok)

        fake_session_loop(%{
          state
          | mcp_statuses: Enum.reject(state.mcp_statuses, &(&1.name == name))
        })

      {:"$gen_call", from, :refresh} ->
        send(state.owner, {:refreshed, self()})
        GenServer.reply(from, state.refresh)
        fake_session_loop(state)

      {:"$gen_call", from, {:set_tool_access, names, enabled?}} ->
        send(state.owner, {:set_tool_access, names, enabled?})
        GenServer.reply(from, {:ok, names})
        fake_session_loop(state)

      {:"$gen_call", from, {:resolve, call_id, {:answer, answer}}} ->
        send(state.owner, {:answered, call_id, answer})
        GenServer.reply(from, :ok)
        fake_session_loop(state)

      {:"$gen_call", from, {:cancel, _reason}} ->
        send(state.owner, :cancelled)
        GenServer.reply(from, :ok)
        fake_session_loop(state)

      {:"$gen_call", from, {:resolve, call_id, {:decision, decision}}} ->
        send(state.owner, {:resolved, call_id, decision})
        GenServer.reply(from, :ok)
        fake_session_loop(state)

      {:"$gen_call", from, :clear} ->
        send(state.owner, :cleared)
        GenServer.reply(from, {:ok, %{entries: 2}})
        fake_session_loop(state)

      {:"$gen_call", from, :compact} ->
        send(state.owner, :compacting)
        GenServer.reply(from, state.compact_result)
        fake_session_loop(state)

      {:"$gen_call", from, {:attach, target}} ->
        send(state.owner, {:attach, target})
        GenServer.reply(from, {:error, "unexpected attach"})
        fake_session_loop(state)
    end
  end
end
