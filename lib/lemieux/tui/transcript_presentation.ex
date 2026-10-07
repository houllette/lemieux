# Durable transcript entries and live child events use the same row vocabulary.
# This projector owns their presentation, while the TUI callback owns mutable
# editor state, viewport anchoring, and live event delivery.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.TranscriptPresentation do
    @moduledoc "Projects saved events into rows and formats delegation rows."

    alias Lemieux.Extensions.Verify
    alias Lemieux.ID.Shorthand
    alias Lemieux.Transcript
    alias Lemieux.TUI.Activity
    alias Lemieux.TUI.Blocks
    alias Lemieux.TUI.ToolText

    # The tag a shipped stop hook puts first so the model can tell which rule
    # spoke; the row's glyph already says the harness did.
    @hook_tag ~r/\A\[lmx [^\]\n]*\]\s*/

    @doc "Summarizes a finished delegation group."
    @spec group_summary(map()) :: String.t()
    def group_summary(%{"status" => status, "results" => results}) when is_list(results),
      do: "delegation #{status} · #{investigations(length(results))}"

    def group_summary(%{"status" => status}), do: "delegation #{status}"
    def group_summary(_payload), do: "delegation finished"

    defp investigations(count), do: Activity.investigations(count)

    @doc "Matches a child row by durable child ID."
    @spec child_row?(term(), term()) :: boolean()
    def child_row?({:subagent_child, %{id: id}}, id), do: true
    def child_row?(_row, _id), do: false

    # What a child was sent to do, short enough to sit on the end of its row.
    # The objective is prose a model wrote and can run to a paragraph.
    @brief_length 56

    @doc "Shortens a child objective for its transcript row."
    @spec brief(term()) :: String.t() | nil
    def brief(objective) when is_binary(objective) do
      collapsed = objective |> String.replace(~r/\s+/, " ") |> String.trim()

      if String.length(collapsed) > @brief_length,
        do: String.slice(collapsed, 0, @brief_length - 1) <> "…",
        else: collapsed
    end

    def brief(_objective), do: nil

    # A ULID in a row that scrolls past is nothing a person can act on, and telling
    # parallel scouts apart is this column's whole job. `Lemieux.ID.Shorthand`
    # derives a name from any id, so the same child is called the same thing in
    # every row about it without anything being stored. Kept beside the id, which is
    # what live updates and replay match on — two colliding names still keep
    # separate rows.
    @doc "Gives a child a stable short name from its ID."
    @spec child_name(term()) :: String.t()
    def child_name(%{} = payload), do: child_name(payload["child_id"])
    def child_name(child_id) when is_binary(child_id), do: Shorthand.of(child_id)
    def child_name(_missing), do: "child"

    # The failure flag lives on the result payload and nowhere else. Rows are
    # what survive into the transcript window, so it has to be read here or it
    # is lost by the time anything draws.
    @doc "Returns the tone of a recorded tool result."
    @spec tone(map()) :: :error | :ok
    def tone(%{"error" => true}), do: :error
    def tone(_payload), do: :ok

    @doc "Rebuilds the visible transcript rows from durable session entries."
    @spec lines([map()], map()) :: [term()]
    def lines(entries, view) do
      entries
      |> Enum.reduce({[], %{}}, &transcript_entry(&1, &2, view))
      |> elem(0)
      |> space_turns()
    end

    # An attempt the stream broke off: its words dimmed and marked, never the
    # answer. The live screen marks it the same way when it happens.
    defp transcript_entry(
           %{type: :assistant, payload: %{"partial" => true} = payload},
           {lines, calls},
           _view
         ) do
      text =
        payload
        |> Map.get("content", [])
        |> Enum.flat_map(fn
          %{"type" => "text", "text" => text} -> String.split(text, "\n")
          _other -> []
        end)
        |> Enum.map(&{:interrupted, &1})

      {lines ++
         text ++
         [{:interrupted, "interrupted · this partial answer was kept, and is not sent back"}],
       calls}
    end

    # The same block recognition the live screen does, over the finished
    # text, so a resumed answer draws the fences and tables it drew live.
    defp transcript_entry(%{type: :assistant, payload: payload}, {lines, calls}, view) do
      text =
        payload
        |> Map.get("content", [])
        |> Enum.flat_map(fn
          %{"type" => "text", "text" => text} -> Blocks.rows(text, view.theme)
          _other -> []
        end)

      lines = lines ++ text

      Enum.reduce(Map.get(payload, "tool_calls", []), {lines, calls}, fn call, {lines, calls} ->
        id = call["id"] || "tool"
        rows = ToolText.call(call, ToolText.exploration_tail?(lines), view.renderers, view.theme)

        {lines ++ rows, Map.put(calls, id, call)}
      end)
    end

    defp transcript_entry(%{type: :tool_result, payload: payload}, {lines, calls}, view) do
      id = payload["call_id"] || "tool"
      known? = Map.has_key?(calls, id)

      call =
        Map.get(calls, id, %{
          "id" => id,
          "name" => payload["name"],
          "arguments" => payload["arguments"] || %{}
        })

      lines =
        if known?,
          do: lines,
          else:
            lines ++
              ToolText.call(call, ToolText.exploration_tail?(lines), view.renderers, view.theme)

      lines =
        case ToolText.result(call, payload, view.theme, view.renderers) do
          :none ->
            lines

          {:output, output} ->
            lines ++ ToolText.output_rows(id, output, view.width, tone(payload))

          {:answer, answer} ->
            Enum.reject(lines, &ToolText.answer?(&1, id)) ++ ToolText.answer_rows(id, answer)

          {:replace, rows} ->
            Enum.reject(lines, &(ToolText.call_id(&1) == id)) ++ rows
        end

      {lines, Map.delete(calls, id)}
    end

    # A spawn and its result are two entries about one child, so the second updates
    # the row the first made. Live, the same child is one row for the same reason; a
    # resumed delegation showing every child twice would be a different shape of
    # transcript for the same run.
    defp transcript_entry(%{type: type, payload: payload}, {lines, calls}, _view)
         when type in [:subagent_spawn, :subagent_result],
         do: {merged_child(lines, spawned_child(payload)), calls}

    defp transcript_entry(entry, {lines, calls}, _view), do: {lines ++ entry_lines(entry), calls}

    defp merged_child(lines, child) do
      case Enum.find_index(lines, &child_row?(&1, child.id)) do
        nil ->
          lines ++ [{:subagent_child, child}]

        index ->
          List.update_at(lines, index, fn {:subagent_child, existing} ->
            {:subagent_child, merge_child(existing, child)}
          end)
      end
    end

    # A result records the status and the kind but not the brief, so a merge
    # that took every field would erase what the spawn knew.
    defp merge_child(existing, update) do
      Map.merge(existing, update, fn
        _key, kept, nil -> kept
        _key, _kept, replacement -> replacement
      end)
    end

    defp space_turns(lines) do
      lines
      |> Enum.reduce([], fn line, acc ->
        if turn_boundary?(line, acc), do: [line, {:space, ""} | acc], else: [line | acc]
      end)
      |> Enum.reverse()
    end

    defp turn_boundary?({:you, _text}, [row | _rest]), do: Blocks.model_row?(row)
    defp turn_boundary?(_line, _acc), do: false

    # A message a stop hook sent the model is the harness talking, not the
    # person; `harness_lines/1` says it in that voice.
    defp entry_lines(%{type: :user, payload: %{"text" => text}} = entry) do
      case harness_lines(entry) do
        [] -> split_lines(:you, text)
        lines -> lines
      end
    end

    defp entry_lines(%{type: :error, payload: payload}),
      do: [{:lmx, "error: #{payload["reason"] || inspect(payload)}"}]

    defp entry_lines(%{type: :cancelled}), do: [{:lmx, "— cancelled —"}]

    # The same rows the live screen draws, rebuilt from the entries that recorded the
    # same facts — a resumed delegation used to label three children with their
    # shared definition id and carry no brief. What cannot be rebuilt is the activity
    # line: a child's tool calls are in the *child's* transcript, which the parent
    # never saw.
    defp entry_lines(%{type: :subagent_group_result, payload: payload}),
      do: [{:summary, group_summary(payload)}]

    defp entry_lines(_entry), do: []

    defp spawned_child(payload) do
      %{
        id: payload["child_id"],
        name: child_name(payload),
        kind: payload["definition_id"],
        goal: payload |> get_in(["task", "objective"]) |> brief(),
        status: payload["status"] || "queued",
        activity: nil,
        count: 1,
        text: nil
      }
    end

    defp split_lines(who, text) when is_binary(text),
      do: Enum.map(String.split(text, "\n"), &{who, &1})

    @doc "Whether a user message is one the verify extension wrote."
    @spec verify?(String.t()) :: boolean()
    def verify?(text) when is_binary(text), do: String.starts_with?(text, Verify.marker())
    def verify?(_text), do: false

    @doc "A verify message's rows, without its marker."
    @spec verify_lines(String.t()) :: [{:verify, String.t()}]
    def verify_lines(text) do
      text
      |> String.replace_prefix(Verify.marker(), "")
      |> String.trim_leading()
      |> then(&split_lines(:verify, &1))
    end

    @doc """
    The rows for a user entry the harness wrote, or `[]` for one the person
    did.

    A stop hook's message (`Lemieux.Transcript.stop_hook?/1`) is drawn as
    `:hook` rows without its `[lmx …]` tag, and verify's as `:verify` rows
    with its check mark — including verify messages from before the session
    marked stop hooks' words, which only the tag identifies.
    """
    @spec harness_lines(entry :: Lemieux.Entry.t()) :: [{:hook | :verify, String.t()}]
    def harness_lines(%{type: :user, payload: %{"text" => text}} = entry) when is_binary(text) do
      cond do
        verify?(text) -> verify_lines(text)
        Transcript.stop_hook?(entry) -> split_lines(:hook, String.replace(text, @hook_tag, ""))
        true -> []
      end
    end

    def harness_lines(_entry), do: []
  end
end
