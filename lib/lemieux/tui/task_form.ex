if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.TaskForm do
    @moduledoc "Native fields for observing an existing external run; no command or JSON editor."
    alias ExRatatui.Event.{Key, Mouse, Paste}
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Widgets.{Paragraph, Textarea}
    alias Lemieux.TUI
    alias Lemieux.TUI.{Editor, Screen, Takeover, TaskPanel}

    @doc false
    @spec open(state :: TUI.t()) :: TUI.t()
    def open(state) do
      case TaskPanel.cache(state).sources do
        [] ->
          put_in(state.modal.notice, "No external observation sources are available.")

        sources ->
          form = %{
            sources: sources,
            source: 0,
            index: 0,
            values: %{"minutes" => "60"},
            follow_up?: Map.get(TaskPanel.cache(state), :auto_continue?, true),
            input: ExRatatui.textarea_new()
          }

          state
          |> put_in([Access.key!(:modal), :form], form)
          |> put_in([Access.key!(:modal), :notice], nil)
      end
    end

    @doc false
    @spec key(event :: Key.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def key(%Key{code: "esc"}, state), do: {:noreply, put_in(state.modal.form, nil)}
    def key(%Key{code: "enter", modifiers: ["ctrl"]}, state), do: {:noreply, submit(state)}
    def key(%Key{code: "back_tab"}, state), do: {:noreply, focus(state, -1)}

    def key(%Key{code: "tab", modifiers: modifiers}, state),
      do: {:noreply, focus(state, if("shift" in modifiers, do: -1, else: 1))}

    def key(%Key{code: code, modifiers: []}, %{modal: %{form: %{index: 0}}} = state)
        when code in ["left", "right", "enter", " "] do
      form = state.modal.form

      source =
        Integer.mod(form.source + if(code == "left", do: -1, else: 1), length(form.sources))

      {:noreply, put_in(state.modal.form.source, source)}
    end

    def key(%Key{code: code, modifiers: []}, state) when code in ["enter", " "] do
      form = state.modal.form
      count = length(fields(form))

      cond do
        form.index == count + 2 ->
          {:noreply, submit(state)}

        form.index == count + 1 ->
          {:noreply, put_in(state.modal.form.follow_up?, not form.follow_up?)}

        code == "enter" ->
          {:noreply, focus(state, 1)}

        true ->
          edit(state, code, [])
      end
    end

    def key(%Key{code: code, modifiers: modifiers}, state), do: edit(state, code, modifiers)

    defp edit(state, code, modifiers) do
      form = state.modal.form

      if form.index in 1..length(fields(form)) and
           not Enum.any?(modifiers, &(&1 in ["super", "meta", "hyper"])) do
        :ok = ExRatatui.textarea_handle_key(form.input, code, modifiers)
      end

      {:noreply, state}
    end

    defp store(state) do
      form = state.modal.form

      case Enum.at(fields(form), form.index - 1) do
        {key, _label} when form.index > 0 ->
          value =
            form.input
            |> ExRatatui.textarea_get_value()
            |> String.replace(~r/[\r\n]/, "")
            |> String.slice(0, 512)

          put_in(state.modal.form.values, Map.put(form.values, key, value))

        _other ->
          state
      end
    end

    defp focus(state, by) do
      state = store(state)
      form = state.modal.form
      index = Integer.mod(form.index + by, length(fields(form)) + 3)

      value =
        case Enum.at(fields(form), index - 1) do
          {key, _label} when index > 0 -> form.values[key] || ""
          _other -> ""
        end

      :ok = Editor.replace(form.input, value)
      put_in(state.modal.form.index, index)
    end

    defp submit(state) do
      state = store(state)
      form = state.modal.form
      values = Map.take(form.values, Enum.map(fields(form), &elem(&1, 0)))
      TaskPanel.add(state, source(form), values, form.follow_up?)
    end

    defp source(form), do: Enum.at(form.sources, form.source)

    defp fields(form) do
      target =
        if source(form) == "github",
          do: [
            {"repository", "Repository (owner/repo)"},
            {"run_id", "Run ID"},
            {"sha", "Commit SHA (40 characters)"}
          ],
          else: [{"run_id", "Run ID"}]

      target ++ [{"minutes", "Deadline (minutes)"}]
    end

    @doc false
    @spec paste(event :: Paste.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def paste(%Paste{content: content}, state) do
      form = state.modal.form

      if form.index in 1..length(fields(form)) do
        text = content |> String.replace(~r/[\r\n]/, "") |> String.slice(0, 512)
        :ok = ExRatatui.textarea_insert_str(form.input, text)
      end

      {:noreply, state}
    end

    @doc false
    @spec mouse(event :: Mouse.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def mouse(%Mouse{kind: "down", button: "left", x: x, y: y}, state) do
      area = Takeover.area(Screen.panes(state), state.terminal.height)
      index = y - area.y - 2 + visible_start(state.modal.form, area)
      form = state.modal.form
      count = length(fields(form))

      if x > area.x and x < area.x + area.width - 1 and index in 0..(count + 2) do
        state = focus(state, index - form.index)

        if index in [0, count + 1, count + 2],
          do: key(%Key{code: "enter", modifiers: []}, state),
          else: {:noreply, state}
      else
        {:noreply, state}
      end
    end

    def mouse(_event, state), do: {:noreply, state}

    @doc false
    @spec render(state :: TUI.t(), panes :: map()) :: [{term(), Rect.t()}]
    def render(state, panes) do
      area = Takeover.area(panes, state.terminal.height)
      form = state.modal.form
      fields = fields(form)

      labels =
        [{nil, "Source: ‹ #{source(form)} ›"}] ++
          Enum.map(fields, fn {key, label} ->
            {key, "#{label}: #{form.values[key] || ""}"}
          end) ++
          [
            {nil,
             "[#{if(form.follow_up?, do: "x", else: " ")}] Continue automatically when complete"},
            {nil, "[ Create watch ]"}
          ]

      room = max(area.height - 5, 1)
      start = visible_start(form, area)

      rows =
        labels
        |> Enum.with_index()
        |> Enum.slice(start, room)
        |> Enum.flat_map(fn {{key, label}, index} ->
          rect = row_rect(area, index - start + 2)

          field_widgets(form, fields, key, label, index, rect)
        end)

      widgets =
        [
          {%Paragraph{
             text: "Observe an existing run. This does not start or cancel external work."
           }, row_rect(area, 1)}
        ] ++
          rows ++
          [
            {%Paragraph{
               text:
                 state.modal.notice || "Tab next · ←/→ source · Space toggle · Ctrl-Enter create"
             }, row_rect(area, max(area.height - 3, 0))},
            {%Paragraph{text: "Esc back"}, row_rect(area, max(area.height - 2, 0))}
          ]

      Takeover.frame(area, " Add external watch ") ++
        Enum.filter(widgets, fn {_widget, rect} -> rect.width > 0 and rect.height > 0 end)
    end

    defp field_widgets(%{index: index} = form, fields, key, _label, index, rect)
         when not is_nil(key) do
      {_key, prompt} = Enum.find(fields, &(elem(&1, 0) == key))
      label_width = min(String.length(prompt) + 2, rect.width)

      [
        {%Textarea{state: form.input, block: nil},
         %{rect | x: rect.x + label_width, width: rect.width - label_width}},
        {%Paragraph{text: "#{prompt}: "}, %{rect | width: label_width}}
      ]
    end

    defp field_widgets(form, _fields, _key, label, index, rect),
      do: [
        {%Paragraph{text: if(index == form.index, do: "› " <> label, else: "  " <> label)}, rect}
      ]

    defp visible_start(form, area) do
      room = max(area.height - 5, 1)
      max(min(form.index - div(room, 2), length(fields(form)) + 3 - room), 0)
    end

    defp row_rect(area, top),
      do: %Rect{
        x: area.x + min(1, area.width),
        y: area.y + min(top, area.height),
        width: max(area.width - 2, 0),
        height: if(top < area.height, do: 1, else: 0)
      }
  end
end
