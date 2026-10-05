# The mouse and the transcript viewport: wheel scrolling (painted once per
# frame), dragging to select and copy, clicking links and the model picker's
# tabs, and the arithmetic that says which row is under the pointer.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Pointer do
    @moduledoc "Handles mouse input and the transcript viewport for a `Lemieux.TUI`."

    alias Lemieux.TUI
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.Flash
    alias Lemieux.TUI.Links
    alias Lemieux.TUI.Notices
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Selection
    alias Lemieux.TUI.Transcript
    alias Lemieux.TUI.Window

    @scroll_frame_ms 16
    @scroll_step 3

    # Dragging past an edge scrolls. Per event rather than on a repeating timer, so
    # it follows the hand instead of running away from it and a hand held still
    # stops. A wheel notch per event rather than a single row, because the terminal
    # reports a pointer clamped to its own grid: once the drag reaches the top row,
    # the only way to cover a long answer is to keep moving *across* the edge.
    # Symmetric rather than proportional to the overshoot — there is one row to push
    # into above and a status line and input box below, so proportional would make
    # dragging back through history slower than dragging forward through it.
    @drag_scroll_step @scroll_step

    @typep reply :: {:noreply, TUI.t()} | {:noreply, TUI.t(), keyword()}

    @doc false
    @spec step() :: pos_integer()
    def step, do: @scroll_step

    @doc false
    @spec mouse(ExRatatui.Event.Mouse.t(), TUI.t()) :: reply()
    def mouse(
          %ExRatatui.Event.Mouse{kind: "scroll_up"},
          %{terminal: %{scroll_coalesce?: true}} = state
        ),
        do: defer_scroll(state, @scroll_step)

    def mouse(
          %ExRatatui.Event.Mouse{kind: "scroll_down"},
          %{terminal: %{scroll_coalesce?: true}} = state
        ),
        do: defer_scroll(state, -@scroll_step)

    def mouse(%ExRatatui.Event.Mouse{kind: "scroll_up"}, state),
      do: {:noreply, scroll(state, @scroll_step)}

    def mouse(%ExRatatui.Event.Mouse{kind: "scroll_down"}, state),
      do: {:noreply, scroll(state, -@scroll_step)}

    # Dragging in the transcript selects it. The screen has to do this itself:
    # capturing the mouse for the wheel takes the terminal's own drag
    # selection with it, and a transcript you cannot copy an error message out
    # of is a bad trade however good the scrolling is.
    def mouse(%ExRatatui.Event.Mouse{kind: "down", button: "left"} = event, state) do
      cond do
        scrollback_marker_at?(state, event) ->
          {:noreply, %{state | scroll: 0, selection: nil}}

        # The notice box is drawn above the transcript, not in it: a click
        # there opens its item's link, if it has one, and selects nothing.
        in_notices?(state, event) ->
          {:noreply, open_notice_link(state, event)}

        tab = Composer.model_tab_at(state, event) ->
          {:ok, tab} = tab
          {:noreply, %{state | model_tab: tab, command_index: 0}}

        # A link opens on release, whatever modifier the press reports, so a
        # drag that starts on one still selects. Super+click once opened on
        # the press, and never did: terminals report mouse modifiers in the
        # button code, which has bits for Shift, Alt and Ctrl and none for
        # Super, so no click arrives with it.
        link = clicked_link(state, event) ->
          {:noreply, put_in(state.terminal.link_press, link)}

        true ->
          {:noreply, begin_selection(state, event)}
      end
    end

    def mouse(%ExRatatui.Event.Mouse{kind: "drag", button: "left"} = event, state) do
      state =
        case state.terminal.link_press do
          {_target, point} ->
            state
            |> put_in([Access.key!(:terminal), :link_press], nil)
            |> Map.put(:selection, Selection.start(point))

          nil ->
            state
        end

      {:noreply, extend_selection(state, event)}
    end

    # Releasing copies. A terminal's own copy shortcut never reaches an application
    # that has taken the mouse, so a selection waiting to be told to copy never would
    # be. Silent on success, because the highlight is the receipt.
    def mouse(%ExRatatui.Event.Mouse{kind: "up", button: "left"}, state) do
      case state.terminal.link_press do
        {target, _point} ->
          {:noreply,
           state |> put_in([Access.key!(:terminal), :link_press], nil) |> open_target(target)}

        nil ->
          {:noreply, copy_selection(state)}
      end
    end

    def mouse(_event, state), do: {:noreply, state}

    # Clamped by `Window.rows/5`, because how far back the transcript goes depends
    # on how its lines wrap. Measured with the renderer the pane draws with: the
    # two-tuple default has no clause for a tool-output row and crashed the app on
    # the first Page Up over one.
    @doc false
    @spec scroll(TUI.t(), integer()) :: TUI.t()
    def scroll(state, by) do
      target = max(state.scroll + by, 0)
      state = warm_rows(state, target + Screen.visible(state))
      %{state | scroll: view(state, target).offset}
    end

    @doc false
    @spec page(TUI.t()) :: pos_integer()
    def page(state), do: max(Screen.visible(state) - 2, 1)

    @doc false
    @spec flush_scroll(TUI.t()) :: TUI.t()
    def flush_scroll(state) do
      state = put_in(state.terminal.scroll_pending, nil)
      state = warm_rows(state, state.scroll + Screen.visible(state))
      %{state | scroll: view(state).offset}
    end

    # The frame timer a wheel burst set. Only the burst's own token paints;
    # a stale one arrives after that burst was already flushed by some other
    # event, and asks for no frame.
    @doc false
    @spec scroll_flush(TUI.t(), reference()) :: reply()
    def scroll_flush(%TUI{terminal: %{scroll_pending: %{token: token}}} = state, token),
      do: {:noreply, flush_scroll(state)}

    def scroll_flush(state, _token), do: {:noreply, state, render?: false}

    @doc false
    @spec open_link_result(TUI.t(), term()) :: {:noreply, TUI.t()}
    def open_link_result(state, {:error, reason}),
      do: {:noreply, Flash.show(state, open_error(reason))}

    def open_link_result(state, _result), do: {:noreply, state}

    defp defer_scroll(state, by) do
      pending =
        case state.terminal.scroll_pending do
          nil ->
            token = make_ref()
            Process.send_after(self(), {:scroll_flush, token}, @scroll_frame_ms)
            %{token: token}

          pending ->
            pending
        end

      state =
        state
        |> put_in([Access.key!(:terminal), :scroll_pending], pending)
        |> Map.update!(:scroll, &max(&1 + by, 0))

      {:noreply, state, render?: false}
    end

    defp warm_rows(state, wanted) do
      width = Screen.columns(state)
      theme = Screen.theme(state)

      cached =
        case state.terminal.row_cache do
          %{width: ^width, theme: ^theme, rows: rows} -> rows
          _other -> %{}
        end

      {cached, _count} =
        Enum.reduce_while(state.lines, {cached, 0}, fn line, {rows, count} ->
          rendered = Map.get(rows, line) || Screen.rich_rows(line, width, theme)
          rows = Map.put_new(rows, line, rendered)
          count = count + length(rendered)

          if count >= wanted, do: {:halt, {rows, count}}, else: {:cont, {rows, count}}
        end)

      put_in(state.terminal.row_cache, %{width: width, theme: theme, rows: cached})
    end

    defp scrollback_marker_at?(%{scroll: 0}, _event), do: false

    defp scrollback_marker_at?(state, %ExRatatui.Event.Mouse{x: x, y: y}) do
      pane = Screen.transcript_pane(state)
      title = Screen.scrollback_title(state.scroll)
      start = pane.x + div(pane.width - String.length(title), 2)

      y == pane.y + pane.height - 1 and x >= start and x < start + String.length(title)
    end

    defp begin_selection(state, event) do
      case cell(state, view(state), event) do
        nil -> %{state | selection: nil}
        point -> %{state | selection: Selection.start(point)}
      end
    end

    defp in_notices?(state, %ExRatatui.Event.Mouse{x: x, y: y}),
      do: Notices.inside?(Map.get(Screen.panes(state), :notices), x, y)

    defp open_notice_link(state, %ExRatatui.Event.Mouse{x: x, y: y}) do
      case Notices.link_at(state, Map.get(Screen.panes(state), :notices), {x, y}) do
        nil -> state
        target -> open_target(state, target)
      end
    end

    defp clicked_link(state, event) do
      visible = view(state)

      with point when not is_nil(point) <- cell(state, visible, event),
           target when not is_nil(target) <-
             Links.target_at(visible, point, state.references.cwd, Screen.columns(state)) do
        {target, point}
      else
        _other -> nil
      end
    end

    defp open_target(state, target) do
      opener = state.terminal.open_link
      app = self()
      Task.start(fn -> send(app, {:open_link_result, opener.(target)}) end)
      %{state | selection: nil}
    end

    defp extend_selection(%TUI{selection: nil} = state, _event), do: state

    defp extend_selection(state, %ExRatatui.Event.Mouse{x: x, y: y}) do
      state = autoscroll(state, y)
      pane = Screen.transcript_pane(state)
      view = view(state)

      case length(view.rows) do
        0 ->
          state

        count ->
          # Clamped rather than dropped, unlike the press: a drag that wanders
          # off the pane should extend to the edge it left by, which is what
          # every other text selection on the machine does. The press stays
          # strict so that clicking into the input box does not quietly arm a
          # transcript selection.
          row = (y - pane.y - 1) |> max(0) |> min(count - 1)
          point = {view.bottom + (count - 1 - row), max(x - pane.x - 1, 0)}

          %{state | selection: Selection.extend(state.selection, point)}
      end
    end

    defp autoscroll(state, y) do
      pane = Screen.transcript_pane(state)

      cond do
        y < pane.y + 1 -> scroll(state, @drag_scroll_step)
        y > pane.y + pane.height - 2 -> scroll(state, -@drag_scroll_step)
        true -> state
      end
    end

    defp copy_selection(%TUI{selection: nil} = state), do: state

    defp copy_selection(state) do
      if Selection.empty?(state.selection) do
        # A click is a drag of no distance, and clearing on it is how somebody
        # dismisses the last selection without learning a key.
        %{state | selection: nil}
      else
        state.selection |> Selection.text(covering(state, state.selection)) |> copied(state)
      end
    end

    # The rows the selection covers, which is not the same window as the one
    # on screen once a drag has scrolled: copying what is visible would
    # silently hand over a fragment of what is highlighted. Asking the window
    # for the selection's own extent keeps the cost the size of the drag.
    defp covering(state, selection) do
      {deepest, shallowest} = Selection.span(selection)

      Window.view(
        state.lines,
        Screen.columns(state),
        deepest - shallowest + 1,
        shallowest,
        Screen.row_renderer(state, Screen.columns(state))
      )
    end

    defp copied("", state), do: %{state | selection: nil}

    defp copied(text, state) do
      case state.terminal.clipboard.(text) do
        :ok ->
          Flash.show(state, "copied #{String.length(text)} characters")

        {:error, :unsupported_transport} ->
          Transcript.say(
            %{state | selection: nil},
            :lmx,
            "this terminal transport has no clipboard · /copy takes the latest answer"
          )

        other ->
          Transcript.say(
            %{state | selection: nil},
            :lmx,
            "could not copy the selection: #{inspect(other)}"
          )
      end
    end

    # Screen coordinates to a transcript cell, or nil on the border, the status line,
    # the input box, or the space a short transcript leaves below itself. Measured
    # from the transcript pane's own origin, so a layout that put the pane
    # somewhere else still selects the row under the pointer. The answer is the
    # depth the window says that row is at, which is what makes it outlive the
    # frame it was asked about.
    defp cell(state, view, %ExRatatui.Event.Mouse{x: x, y: y}) do
      pane = Screen.transcript_pane(state)
      count = length(view.rows)
      row = y - pane.y - 1
      column = x - pane.x - 1

      if row >= 0 and row < min(Screen.visible(state, pane), count) and column >= 0 and
           column < pane.width - 2,
         do: {view.bottom + (count - 1 - row), column}
    end

    # What the pane is showing, recomputed rather than remembered: `render/2`
    # runs at frame rate and storing its output would make every frame write
    # to the struct. The arithmetic is the window's, and it is bounded by the
    # viewport rather than the transcript.
    defp view(state, scroll \\ nil) do
      pane = Screen.transcript_pane(state)

      Window.view(
        state.lines,
        Screen.inner(pane.width),
        Screen.visible(state, pane),
        scroll || state.scroll,
        Screen.row_renderer(state, Screen.inner(pane.width))
      )
    end

    defp open_error(:opener_unavailable), do: "could not open link · no opener available"
    defp open_error({:opener_failed, status}), do: "could not open link · opener exited #{status}"
    defp open_error({:refused, why}) when is_binary(why), do: "not opened · " <> why
    defp open_error(_reason), do: "could not open link"
  end
end
