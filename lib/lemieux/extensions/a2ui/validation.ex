defmodule Lemieux.Extensions.A2UI.Validation do
  @moduledoc """
  Bounded diagnostics for visualization fences in one assistant answer.

  Ordinary fences are tracked too: a Mermaid example inside a Markdown code
  sample is source, not a failed drawing. Only complete fences are prepared;
  incomplete ones receive a closing-fence diagnostic. At most 32 visualizations
  are checked, four failures reported and 16 KiB retained per fence.
  """
  alias Lemieux.Extensions.A2UI.{Diagram, Rendering}

  @open ~r/^\s{0,3}(`{3,}|~{3,})\s*([^\s`]*)/u
  @close ~r/^\s{0,3}(`{3,}|~{3,})\s*$/u
  @visual ~w(a2ui mermaid)
  @limit 16_384

  @doc "Returns concise failures from displayed fences, without inspecting prose or ordinary code."
  @spec diagnostics(text :: String.t()) :: [String.t()]
  def diagnostics(text) do
    if String.valid?(text) do
      state =
        Enum.reduce_while(String.split(text, "\n"), %{open: nil, count: 0, errors: []}, &line/2)

      state = unfinished(state)
      Enum.reverse(state.errors)
    else
      ["Visualization text must be valid UTF-8."]
    end
  end

  defp line(_line, %{errors: errors} = state) when length(errors) >= 4, do: {:halt, state}

  defp line(line, %{open: nil} = state) do
    case Regex.run(@open, line) do
      [whole, fence, info] ->
        language = String.downcase(info)
        count = state.count + if(language in @visual, do: 1, else: 0)

        if count > 32 do
          # Stop local validation at its work budget without reporting a
          # valid, merely unexamined drawing as a render failure.
          {:halt, state}
        else
          caption = String.replace_prefix(line, whole, "") |> String.trim() |> String.slice(0, 96)

          open = %{
            fence: fence,
            language: language,
            caption: caption,
            lines: [],
            bytes: 0,
            oversized?: false
          }

          {:cont, %{state | open: open, count: count}}
        end

      _prose ->
        {:cont, state}
    end
  end

  defp line(line, %{open: open} = state) do
    cond do
      closes?(line, open.fence) -> {:cont, checked(state)}
      open.language in @visual -> {:cont, %{state | open: collect(open, line)}}
      true -> {:cont, state}
    end
  end

  defp collect(open, line) do
    bytes = open.bytes + byte_size(line) + if(open.lines == [], do: 0, else: 1)
    oversized? = open.oversized? or bytes > @limit

    %{
      open
      | bytes: min(bytes, @limit + 1),
        oversized?: oversized?,
        lines: if(oversized?, do: [], else: [line | open.lines])
    }
  end

  defp closes?(line, opener) do
    case Regex.run(@close, line) do
      [_, closer] ->
        String.first(closer) == String.first(opener) and
          String.length(closer) >= String.length(opener)

      _not_a_fence ->
        false
    end
  end

  defp checked(%{open: %{language: language} = open} = state) when language in @visual do
    result =
      if open.oversized?,
        do: {:error, "Visualization exceeds the 16 KiB fence limit."},
        else: check(language, open.lines |> Enum.reverse() |> Enum.join("\n"))

    case result do
      {:ok, _prepared} -> %{state | open: nil}
      {:error, message} -> report(state, message)
      :error -> report(state, "Native diagram support is unavailable; use plain Markdown.")
    end
  end

  defp checked(state), do: %{state | open: nil}
  defp check("a2ui", source), do: Rendering.prepare(source)

  defp check("mermaid", source),
    do: Diagram.prepare(%{"component" => "MermaidDiagram", "source" => source})

  defp unfinished(%{open: %{language: language, oversized?: oversized?}} = state)
       when language in @visual do
    message =
      if oversized?,
        do: "Visualization exceeds the 16 KiB fence limit.",
        else: "Missing closing fence; complete the drawing fence."

    report(state, message)
  end

  defp unfinished(state), do: state

  defp report(state, message) do
    caption = if state.open.caption == "", do: state.open.language, else: state.open.caption

    message =
      "Drawing #{state.count} (#{JSON.encode!(caption)}): " <> String.slice(message, 0, 640)

    %{state | open: nil, errors: [message | state.errors]}
  end
end
