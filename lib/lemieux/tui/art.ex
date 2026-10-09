if Code.ensure_loaded?(ExRatatui.Text.Line) do
  defmodule Lemieux.TUI.Art do
    @moduledoc """
    Bounded ASCII components in terminal rows. Animations are initialized at
    an event boundary, never in `render/2`. Resizing only projects their data.
    All data pieces receive explicit values; their gallery simulations are
    never used as session telemetry. Embedders without `ascii` get text.
    """
    alias ExRatatui.Text.Line
    alias Lemieux.TUI.RichText

    @doc "Initializes a component outside the draw loop."
    @spec new(piece :: String.t(), options :: map(), parts :: map() | boolean()) :: term()
    def new(piece, options, parts \\ true), do: new_animation(piece, options, parts)

    @doc "Updates stored options at an event boundary."
    @spec update(animation :: term(), options :: map()) :: term()
    def update(nil, _options), do: nil
    def update(animation, options), do: update_animation(animation, options)

    @doc "Routes an input event to a data component, without effects."
    @spec event(animation :: term(), event :: term()) :: {:ok, term()} | :ignore
    def event(nil, _event), do: :ignore
    def event(animation, event), do: animation_event(animation, event)

    @doc "One real percentage, with a textual value retained in narrow terminals."
    @spec progress(value :: number(), label :: String.t()) :: tuple()
    def progress(value, label) do
      value = value |> max(0) |> min(100)

      {:model_art, new("progress-bar", %{values: [value], labels: [label], style: 1}),
       "#{label} #{Float.round(value / 1, 1)}%"}
    end

    @doc "Projects a stored component at a deterministic width, including fallback."
    @spec lines(
            animation :: term(),
            description :: String.t(),
            width :: pos_integer(),
            theme :: Lemieux.TUI.Theme.t()
          ) :: [Line.t()]
    def lines(nil, description, width, theme), do: fallback(description, width, theme)

    def lines(animation, description, width, theme),
      do: project(animation, description, width, theme)

    @doc "Removes gallery canvas whitespace while preserving relative indentation and styles."
    @spec compact(lines :: [Line.t()]) :: [Line.t()]
    def compact(lines) do
      lines = Enum.reject(lines, &(String.trim(contents(&1)) == ""))
      inset = lines |> Enum.map(&leading_spaces/1) |> Enum.min(fn -> 0 end)
      Enum.map(lines, &trim_canvas(&1, inset))
    end

    defp contents(line), do: Enum.map_join(line.spans, & &1.content)

    defp leading_spaces(line) do
      text = contents(line)
      byte_size(text) - byte_size(String.trim_leading(text, " "))
    end

    defp trim_canvas(line, inset) do
      text = contents(line)
      trailing = byte_size(text) - byte_size(String.trim_trailing(text, " "))
      spans = strip_spaces(line.spans, inset)

      %{line | spans: spans |> Enum.reverse() |> strip_end_spaces(trailing) |> Enum.reverse()}
    end

    defp strip_spaces(spans, count), do: trim_spans(spans, count, :start)
    defp strip_end_spaces(spans, count), do: trim_spans(spans, count, :end)

    defp trim_spans(spans, count, edge) do
      {spans, _count} = Enum.map_reduce(spans, count, &trim_span(&1, &2, edge))
      Enum.reject(spans, &(&1.content == ""))
    end

    defp trim_span(span, count, edge) do
      removed = min(count, byte_size(span.content))
      offset = if edge == :start, do: removed, else: 0
      content = binary_part(span.content, offset, byte_size(span.content) - removed)
      {%{span | content: content}, count - removed}
    end

    @doc "Computes the next decorative frame outside the draw loop."
    @spec frame(animation :: term(), time :: number()) :: {term(), term()}
    def frame(nil, _time), do: {nil, nil}
    def frame(animation, time), do: advance(animation, time)

    @doc "Converts a computed frame before terminal colour adaptation runs."
    @spec paragraph(frame :: term(), mono? :: boolean()) :: ExRatatui.Widgets.Paragraph.t()
    def paragraph(frame, mono? \\ false), do: adapter(frame, mono?)

    defp fallback(description, width, theme),
      do: RichText.lines([{:lmx, description}], width, theme)

    # Both dependencies are optional in the library. A host with ExRatatui but
    # no ascii must still compile with warnings as errors, so the calls
    # themselves are compiled only when their implementation is available.
    if Code.ensure_loaded?(Ascii.ExRatatui) do
      alias Lemieux.TUI.Width

      defp new_animation(piece, options, parts) do
        case Ascii.new(piece, options: options, parts: parts, color: true) do
          {:ok, animation} -> animation
          {:error, reason} -> raise ArgumentError, "invalid ASCII component: #{inspect(reason)}"
        end
      end

      defp advance(animation, time), do: Ascii.frame(animation, time)
      defp update_animation(animation, options), do: Ascii.put_options!(animation, options)
      defp animation_event(animation, event), do: Ascii.handle_event(animation, event)

      defp adapter(frame, mono?),
        do:
          Ascii.ExRatatui.paragraph(frame,
            mode: if(mono?, do: :mono, else: :truecolor),
            ground: false
          )

      defp project(animation, description, width, theme) do
        minimum =
          case animation.meta.bounds[:cols] do
            {minimum, _maximum} -> minimum
            _fixed -> animation.cols
          end

        if width < minimum do
          fallback(description, width, theme)
        else
          animation = resize(animation, width)
          {frame, _animation} = Ascii.frame(animation, 0.0)

          Ascii.ExRatatui.lines(frame,
            mode: if(theme.name == "mono", do: :mono, else: :truecolor),
            ground: false
          )
          |> Enum.map(&fit_line(&1, width, theme))
        end
      end

      defp fit_line(line, width, theme) do
        {spans, _remaining} =
          Enum.map_reduce(line.spans, width, fn span, remaining ->
            text = crop(span.content, remaining)
            style = %{span.style | fg: semantic(span.style.fg, theme)}

            {%{span | content: text, style: style}, max(remaining - Width.of(text), 0)}
          end)

        %{line | spans: spans}
      end

      defp crop(text, width) do
        text
        |> String.graphemes()
        |> Enum.reduce_while({[], 0}, fn grapheme, {acc, used} ->
          size = Width.grapheme(grapheme)

          if used + size <= width,
            do: {:cont, {[grapheme | acc], used + size}},
            else: {:halt, {acc, used}}
        end)
        |> elem(0)
        |> Enum.reverse()
        |> Enum.join()
      end

      defp semantic({:rgb, 88, 166, 255}, theme), do: theme.voices.activity
      defp semantic({:rgb, 63, 185, 80}, theme), do: theme.children.ok
      defp semantic({:rgb, 139, 148, 158}, theme), do: theme.text.muted
      defp semantic({:rgb, 210, 153, 34}, theme), do: theme.children.warn
      defp semantic(colour, _theme), do: colour

      defp resize(animation, width) do
        if Map.has_key?(animation.options, :cols),
          do: Ascii.put_options!(animation, %{cols: min(width, 200)}),
          else: animation
      end
    else
      defp new_animation(_piece, _options, _parts), do: nil
      defp project(_animation, description, width, theme), do: fallback(description, width, theme)
      defp advance(_animation, _time), do: {nil, nil}
      defp update_animation(_animation, _options), do: nil
      defp animation_event(_animation, _event), do: :ignore
      defp adapter(_frame, _mono?), do: %ExRatatui.Widgets.Paragraph{text: ""}
    end
  end
end
