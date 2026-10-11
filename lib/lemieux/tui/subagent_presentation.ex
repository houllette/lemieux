# Live child events update stable rows while saved events use TranscriptPresentation.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.SubagentPresentation do
    @moduledoc "Projects live child events into stable transcript rows."

    alias Lemieux.TUI.Transcript
    alias Lemieux.TUI.TranscriptPresentation

    @doc false
    @spec present(map(), [term()], term()) :: map()
    # One row per child, updated where it sits. One row per *event* put three
    # scouts' statuses and tool activity in arrival order, so reading any one meant
    # picking its name out of interleaved streams. `group_started` draws nothing: it
    # arrives after the `child_queued` events it would introduce. The closing footer
    # carries the count, which is when knowing it is useful.
    defp subagent_rows([_root_id], {:group_finished, payload}),
      do: [
        {:subagent_summary, payload["status"] || "finished",
         TranscriptPresentation.group_summary(payload)}
      ]

    defp subagent_rows(_path, _event), do: []

    def present(state, [_root_id], {:child_queued, payload}) do
      child_id = payload["child_id"]

      update_child(state, child_id, &%{&1 | status: "queued"}, fn ->
        %{
          id: child_id,
          name: TranscriptPresentation.child_name(child_id),
          kind: payload["definition_id"],
          goal: TranscriptPresentation.brief(payload["objective"]),
          status: "queued",
          tokens: nil,
          activity: nil,
          count: 1
        }
      end)
    end

    def present(state, [_root_id], {:child_started, payload}),
      do: child_status(state, payload, "running")

    def present(state, [_root_id], {:child_cancelling, payload}),
      do: child_status(state, payload, "cancelling")

    def present(state, [_root_id], {:child_finished, payload}),
      do: child_status(state, payload, payload["status"] || "finished")

    def present(state, [_root_id, child_id], {:usage, usage}) when is_map(usage),
      do: add_tokens(state, child_id, TranscriptPresentation.child_tokens(usage))

    # A check that let the child continue is worth a word on its row: without
    # one, a scout eight minutes into a long investigation looks exactly like
    # one that hung. A stall needs no row of its own — the cancellation that
    # follows it draws, and the reason is in the envelope.
    def present(state, [_root_id], {:child_assessed, payload}) do
      case payload["outcome"] do
        "progressing" ->
          child_status(
            state,
            payload,
            "running · #{checked_at(payload["elapsed_ms"])}, progressing"
          )

        _stalled ->
          child_status(state, payload, "stalled")
      end
    end

    # A child transcript retains every call. Its row needs only the latest:
    # drawing every repeated read made a stuck scout consume the whole
    # viewport while conveying no new state, so a repeat becomes a count.
    def present(state, [_root_id, child_id], {:tool_call, call}) do
      {signature, text} = subagent_call(call)

      update_child(
        state,
        child_id,
        fn child ->
          count = if child.activity == signature, do: child.count + 1, else: 1

          %{child | activity: signature, count: count, text: text}
        end,
        fn ->
          %{
            id: child_id,
            name: TranscriptPresentation.child_name(child_id),
            kind: nil,
            goal: nil,
            status: "running",
            tokens: nil,
            activity: signature,
            count: 1,
            text: text
          }
        end
      )
    end

    def present(state, path, event),
      do: Transcript.append_rows(state, subagent_rows(path, event))

    defp add_tokens(state, _child_id, nil), do: state

    defp add_tokens(state, child_id, tokens) do
      update_child(
        state,
        child_id,
        fn child ->
          if child.status in [
               "ok",
               "failed",
               "timeout",
               "cancelled",
               "budget_exhausted",
               "finished"
             ],
             do: child,
             else: Map.put(child, :tokens, (Map.get(child, :tokens) || 0) + tokens)
        end,
        fn ->
          child_row_fields(%{"child_id" => child_id}, "running") |> Map.put(:tokens, tokens)
        end
      )
    end

    @doc "Reconciles a child's final recorded usage instead of adding it to live reports."
    @spec result(state :: map(), payload :: map()) :: map()
    def result(state, payload) do
      status = payload["status"] || "finished"
      tokens = TranscriptPresentation.child_tokens(payload["usage"])

      update_child(
        state,
        payload["child_id"],
        fn child ->
          child |> Map.put(:status, status) |> Map.put(:tokens, tokens || Map.get(child, :tokens))
        end,
        fn -> child_row_fields(payload, status) end
      )
    end

    defp child_status(state, payload, status),
      do:
        update_child(
          state,
          payload["child_id"],
          &%{&1 | status: status},
          fn -> child_row_fields(payload, status) end
        )

    defp child_row_fields(payload, status) do
      %{
        id: payload["child_id"],
        name: TranscriptPresentation.child_name(payload),
        kind: payload["definition_id"],
        goal: TranscriptPresentation.brief(payload["objective"]),
        status: status,
        tokens: TranscriptPresentation.child_tokens(payload["usage"]),
        activity: nil,
        count: 1
      }
    end

    # Updated where it already is rather than removed and re-appended: the
    # children are a block, and moving whichever one just did something to
    # the bottom of it reshuffles the block on every event — which is the
    # opposite of being able to watch one of them.
    defp update_child(state, child_id, change, build) do
      case Enum.find_index(state.lines, &TranscriptPresentation.child_row?(&1, child_id)) do
        nil ->
          Transcript.append_rows(state, [{:subagent_child, Map.put_new(build.(), :text, nil)}])

        index ->
          {newer, [{:subagent_child, child} = row | older]} = Enum.split(state.lines, index)
          # A growing token badge can wrap the headline onto another row.
          # Splice keeps the reader and any selection over older rows anchored.
          case change.(child) do
            ^child -> state
            updated -> Transcript.splice(state, newer, [row], [{:subagent_child, updated}], older)
          end
      end
    end

    defp checked_at(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1_000)}s"
    defp checked_at(ms) when is_integer(ms), do: "#{div(ms, 60_000)}m"
    defp checked_at(_ms), do: "now"

    defp subagent_call(call) do
      name = field(call, :name, "name", "tool")
      arguments = field(call, :arguments, "arguments", %{})
      text = activity_text(name, subagent_detail(name, arguments))
      {text, text}
    end

    defp subagent_detail("read", arguments), do: field(arguments, :path, "path", nil)
    defp subagent_detail("bash", arguments), do: field(arguments, :command, "command", nil)
    defp subagent_detail("edit", arguments), do: field(arguments, :path, "path", nil)
    defp subagent_detail("write", arguments), do: field(arguments, :path, "path", nil)
    defp subagent_detail(_name, _arguments), do: nil

    defp activity_text(name, detail) when is_binary(detail) and detail != "",
      do: "#{name} #{detail}"

    defp activity_text(name, _detail), do: name

    defp field(map, atom_key, string_key, default) do
      case Map.fetch(map, atom_key) do
        {:ok, value} -> value
        :error -> Map.get(map, string_key, default)
      end
    end
  end
end
