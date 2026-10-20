if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.TaskSteer do
    @moduledoc "Native steering of the selected delegate; the main composer and its draft remain intact."
    alias ExRatatui.Event.{Key, Mouse, Paste}
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Widgets.{Paragraph, Textarea}
    alias Lemieux.TUI
    alias Lemieux.TUI.{Screen, Takeover, TaskPanel}

    @doc false
    @spec open(state :: TUI.t(), row :: map()) :: TUI.t()
    def open(state, row) do
      form = %{kind: :steer, id: row.id, name: row.name, input: ExRatatui.textarea_new()}

      state
      |> put_in([Access.key!(:modal), :form], form)
      |> put_in([Access.key!(:modal), :notice], nil)
    end

    @doc false
    @spec key(event :: Key.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def key(%Key{code: "esc"}, state), do: {:noreply, put_in(state.modal.form, nil)}
    def key(%Key{code: "enter", modifiers: ["ctrl"]}, state), do: {:noreply, submit(state)}

    def key(%Key{code: code, modifiers: modifiers}, state) do
      :ok = ExRatatui.textarea_handle_key(state.modal.form.input, code, modifiers)
      {:noreply, state}
    end

    defp submit(state) do
      form = state.modal.form
      text = form.input |> ExRatatui.textarea_get_value() |> String.trim()

      if text == "",
        do: put_in(state.modal.notice, "Enter an instruction for this agent."),
        else: TaskPanel.steer(state, form.id, text)
    end

    @doc false
    @spec paste(event :: Paste.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def paste(%Paste{content: content}, state) do
      :ok = ExRatatui.textarea_insert_str(state.modal.form.input, String.slice(content, 0, 8000))
      {:noreply, state}
    end

    @doc false
    @spec mouse(event :: Mouse.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def mouse(%Mouse{kind: "down", button: "left"} = event, state) do
      geometry = geometry(Screen.panes(state))

      cond do
        inside?(event, geometry.send) -> {:noreply, submit(state)}
        inside?(event, geometry.back) -> {:noreply, put_in(state.modal.form, nil)}
        true -> {:noreply, state}
      end
    end

    def mouse(_event, state), do: {:noreply, state}

    @doc false
    @spec render(state :: TUI.t(), panes :: map()) :: [{term(), Rect.t()}]
    def render(state, panes) do
      g = geometry(panes)
      form = state.modal.form

      Takeover.frame(g.area, " Steer #{form.name} ") ++
        [
          {%Paragraph{
             text:
               state.modal.notice ||
                 "Applied at the next model request · existing permissions and budget still apply"
           }, g.label},
          {%Textarea{state: form.input, wrap_mode: :word_or_glyph}, g.input},
          {%Paragraph{text: "[Ctrl-Enter Send]"}, g.send},
          {%Paragraph{text: "[Esc Back]"}, g.back}
        ]
    end

    defp geometry(panes) do
      area = Takeover.tray(panes, 8)
      width = max(area.width - 2, 0)

      label = %Rect{
        x: area.x + min(area.width, 1),
        y: area.y + min(area.height, 1),
        width: width,
        height: min(max(area.height - 2, 0), 1)
      }

      input = %{label | y: label.y + label.height, height: max(area.height - label.height - 3, 0)}

      footer = %{
        label
        | y: area.y + max(area.height - 2, 0),
          height: min(max(area.height - 2, 0), 1)
      }

      send = %{footer | width: min(width, 18)}
      back = %{footer | x: footer.x + send.width, width: min(max(width - send.width, 0), 10)}
      %{area: area, label: label, input: input, send: send, back: back}
    end

    defp inside?(event, rect),
      do:
        event.x >= rect.x and event.x < rect.x + rect.width and event.y >= rect.y and
          event.y < rect.y + rect.height
  end
end
