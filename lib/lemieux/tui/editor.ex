if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Editor do
    @moduledoc "Programmatic replacements for the shared textarea reference."

    alias ExRatatui.CellSession
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Widgets.Textarea

    @doc "Moves the caret to a cell in the textarea's visible inner rectangle."
    @spec place_cursor(
            input :: reference(),
            width :: pos_integer(),
            height :: pos_integer(),
            x :: non_neg_integer(),
            y :: non_neg_integer()
          ) :: :ok
    def place_cursor(input, width, height, x, y) do
      # The NIF exposes neither hit testing nor its viewport offset. Ask its
      # renderer instead: the same editor reference retains the real scroll
      # position and handles word wrapping, tabs and Unicode. Arrow movement
      # preserves the draft and undo history. Work is limited to the visible
      # viewport, rather than walking from the beginning of a long draft.
      align_grapheme(input, "right")
      session = CellSession.new(width, height)

      widget = %Textarea{
        state: input,
        wrap_mode: :word_or_glyph,
        cursor_style: %Style{bg: {:rgb, 1, 2, 3}}
      }

      rect = %Rect{x: 0, y: 0, width: width, height: height}

      try do
        position = caret(session, widget, rect)
        direction = if position > {y, x}, do: "left", else: "right"
        seek(session, widget, rect, {y, x}, position, direction, width * height * 4 + 1)
      after
        CellSession.close(session)
      end

      :ok
    end

    defp seek(_session, _widget, _rect, target, target, _direction, _remaining), do: :ok
    defp seek(_session, _widget, _rect, _target, _position, _direction, 0), do: :ok

    defp seek(session, widget, rect, target, position, direction, remaining) do
      before = ExRatatui.textarea_cursor(widget.state)
      ExRatatui.textarea_handle_key(widget.state, direction)
      align_grapheme(widget.state, direction)
      next = caret(session, widget, rect)
      after_cursor = ExRatatui.textarea_cursor(widget.state)

      cond do
        before == after_cursor ->
          :ok

        direction == "left" and next <= target ->
          :ok

        overshot?(direction, next, target, position) ->
          reverse = if direction == "right", do: "left", else: "right"
          ExRatatui.textarea_handle_key(widget.state, reverse)
          align_grapheme(widget.state, reverse)

          :ok

        true ->
          seek(session, widget, rect, target, next, direction, remaining - 1)
      end
    end

    # The native cursor counts code points. Never leave a click between a
    # base and its combining mark, or inside an emoji sequence.
    defp align_grapheme(input, direction) do
      {row, column} = ExRatatui.textarea_cursor(input)
      text = input |> ExRatatui.textarea_get_value() |> String.split("\n") |> Enum.at(row)

      boundaries = [
        0 | text |> String.graphemes() |> Enum.scan(0, &(length(String.codepoints(&1)) + &2))
      ]

      boundary =
        if direction == "right",
          do: Enum.find(boundaries, &(&1 >= column)),
          else: boundaries |> Enum.take_while(&(&1 <= column)) |> List.last()

      if boundary != column do
        Enum.each(1..abs(boundary - column), fn _ ->
          ExRatatui.textarea_handle_key(input, direction)
        end)
      end
    end

    defp overshot?("right", next, target, position), do: next > target or next < position
    defp overshot?("left", next, _target, position), do: next > position

    defp caret(session, widget, rect) do
      :ok = CellSession.draw(session, [{widget, rect}])

      cell =
        session
        |> CellSession.take_cells()
        |> Map.fetch!(:cells)
        |> Enum.find(&(&1.bg == {:rgb, 1, 2, 3}))

      {cell.row, cell.col}
    end

    # Setting a textarea value reconstructs its Rust-side editor and puts the
    # caret at the beginning. Clear first, then insert at the caret, so a
    # replacement lands at the end even for multiline history.
    @doc false
    @spec replace(reference(), String.t()) :: :ok
    def replace(input, value) do
      :ok = ExRatatui.textarea_set_value(input, "")
      ExRatatui.textarea_insert_str(input, value)
    end
  end
end
