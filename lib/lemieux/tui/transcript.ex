# Transcript mutation and viewport anchoring share one row calculation.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Transcript do
    @moduledoc "Maintains newest-first transcript rows and anchored scroll and selection state."

    alias Lemieux.TUI.Blocks
    alias Lemieux.TUI.RichText
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Selection
    alias Lemieux.TUI.Window

    @doc false
    @spec extend(map(), String.t()) :: map()
    def extend(state, ""), do: state

    # The line being written grows in place. Anything else at the head — a
    # tool row, a closed block — means the answer continues on a new line.
    def extend(%{lines: [head | rest]} = state, text) do
      if Blocks.open?(head) do
        grown = Blocks.extend(head, text)

        %{state | lines: [grown | rest]}
        |> held(rows(state, grown) - rows(state, head))
      else
        say(state, :model, text)
      end
    end

    def extend(state, text), do: say(state, :model, text)

    # A model line is pushed raw and classified when the next one begins;
    # `Lemieux.TUI.Blocks` says why nothing can be known about a line before
    # then. Every other voice closes the line above it first, for the same
    # reason: a fence the model never closed is closed by whatever comes next.
    @doc false
    @spec say(map(), atom(), String.t()) :: map()
    def say(state, :model, text) do
      text
      |> String.split("\n")
      |> Enum.reduce(state, fn line, state -> state |> close_line() |> push_model(line) end)
    end

    def say(state, who, text) do
      state = close_line(state)
      lines = for line <- String.split(text, "\n"), do: {who, line}
      lines = maybe_separate_turn(state.lines, lines, who)
      added = Enum.reduce(lines, 0, fn line, total -> total + rows(state, line) end)

      %{state | lines: Enum.reverse(lines, state.lines)} |> held(added)
    end

    defp push_model(state, line) do
      row = Blocks.open(List.first(state.lines), line)
      %{state | lines: [row | state.lines]} |> held(rows(state, row))
    end

    # Classifies the line being written, now that something else is about to follow
    # it. What it replaces is the newest rows, so everything older moves by exactly
    # the difference in their height — the same arithmetic as an append, through
    # `held/2`.
    @doc false
    @spec close_line(map()) :: map()
    def close_line(%{lines: lines} = state) do
      case Blocks.close(lines, Screen.theme(state)) do
        {0, []} ->
          state

        {count, replacement} ->
          {replaced, rest} = Enum.split(lines, count)
          before = Enum.reduce(replaced, 0, &(rows(state, &1) + &2))
          after_close = Enum.reduce(replacement, 0, &(rows(state, &1) + &2))

          %{state | lines: replacement ++ rest} |> held(after_close - before)
      end
    end

    @doc false
    @spec append_rows(map(), list()) :: map()
    def append_rows(state, []), do: state

    def append_rows(state, lines) do
      state = close_line(state)
      added = Enum.reduce(lines, 0, fn line, total -> total + rows(state, line) end)
      %{state | lines: Enum.reverse(lines, state.lines)} |> held(added)
    end

    defp maybe_separate_turn(lines, new_lines, :you) do
      case List.first(lines) do
        {:summary, _summary} -> [{:space, ""} | new_lines]
        {:compact_result, _report} -> [{:space, ""} | new_lines]
        {:lmx, _output} -> [{:space, ""} | new_lines]
        row -> if Blocks.model_row?(row), do: [{:space, ""} | new_lines], else: new_lines
      end
    end

    defp maybe_separate_turn(_lines, new_lines, _who), do: new_lines

    # Every path that changes what is below the reader goes through here, so "hold
    # your place while the model talks" is one rule rather than one per caller. It is
    # also the one place the rows a selection names move: further from the newest row
    # by exactly `added`, so the highlight follows its own text through a streaming
    # answer. See `Lemieux.TUI.Window.hold/2`.
    defp held(state, 0), do: state

    defp held(state, added),
      do: %{
        state
        | scroll: Window.hold(state.scroll, added),
          selection: Selection.deepen(state.selection, added)
      }

    @doc false
    @spec rows(map(), term()) :: pos_integer()
    def rows(state, line),
      do: length(RichText.lines([line], Screen.columns(state), Screen.theme(state)))
  end
end
