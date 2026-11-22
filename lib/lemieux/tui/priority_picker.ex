if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.PriorityPicker do
    @moduledoc "Presents the active connection's advertised service tiers."

    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.TUI
    alias Lemieux.TUI.Effects
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Modal
    alias Lemieux.TUI.Takeover

    @doc false
    @spec open(TUI.t()) :: TUI.t()
    def open(state) do
      active = state.conversation.priority || legacy(state.conversation.fast_mode)
      choices = state.catalog.priority_tiers
      index = Enum.find_index(choices, &(elem(&1, 0) == active)) || 0
      %{state | modal: %{kind: :priority_picker, choices: choices, index: index}}
    end

    defp legacy("off"), do: "standard"
    defp legacy(tier), do: tier

    @doc false
    @spec key(ExRatatui.Event.Key.t(), TUI.t()) :: {:noreply, TUI.t()}
    def key(event, state) do
      case Keys.action(state.status.keys, event) do
        action when action in [:dismiss, :interrupt] ->
          {:noreply, Modal.close(state)}

        :previous ->
          {:noreply, step(state, -1)}

        :next ->
          {:noreply, step(state, 1)}

        :submit ->
          {tier, _description} = Enum.at(state.modal.choices, state.modal.index)
          Effects.run(Modal.close(state), [{:set_priority, tier}])

        _other ->
          {:noreply, state}
      end
    end

    defp step(state, by) do
      index = Integer.mod(state.modal.index + by, length(state.modal.choices))
      put_in(state.modal.index, index)
    end

    @doc false
    @spec paste(ExRatatui.Event.Paste.t(), TUI.t()) :: {:noreply, TUI.t()}
    def paste(_event, state), do: {:noreply, state}

    @doc false
    @spec render(TUI.t(), map()) :: list()
    def render(state, panes) do
      area = Takeover.area(panes, length(state.modal.choices) + 3)

      body = %{
        area
        | x: area.x + 1,
          y: area.y + 1,
          width: max(area.width - 2, 0),
          height: max(area.height - 2, 0)
      }

      shown = max(body.height - 1, 1)
      offset = max(state.modal.index - shown + 1, 0)

      rows =
        for {{tier, description}, index} <-
              state.modal.choices |> Enum.slice(offset, shown) |> Enum.with_index(offset) do
          cursor = if index == state.modal.index, do: "› ", else: "  "
          cursor <> String.capitalize(tier) <> " · " <> description
        end

      text = Enum.join(rows ++ ["Enter applies to the next request · Esc close"], "\n")
      Takeover.frame(area, " Priority ") ++ [{%Paragraph{text: text}, body}]
    end
  end
end
