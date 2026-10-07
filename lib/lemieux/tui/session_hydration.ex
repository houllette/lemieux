# Session I/O and timer scheduling belong to the app callback. This module
# projects the snapshot it received into the state that screen will display.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.SessionHydration do
    @moduledoc """
    Rebuilds the TUI's conversation, transcript and picker state from a snapshot.

    Reattaching to another session replaces transient rows, scroll position,
    tool call tracking and follow-up state. Pending questions and approvals
    come from the durable snapshot so they can be shown again after resume.
    """

    alias Lemieux.Conversation
    alias Lemieux.ModelSpec
    alias Lemieux.TUI.CatalogState
    alias Lemieux.TUI.ToolText
    alias Lemieux.TUI.TranscriptPresentation

    @doc "Projects session details into a TUI state without session calls or timers."
    @spec hydrate(state :: map(), details :: map(), opts :: map()) :: map()
    def hydrate(state, details, opts) do
      snapshot = details.snapshot
      provider = Map.get(snapshot, :provider) || ModelSpec.provider(snapshot.model)

      # The registry carries over: Conversation.Command.registry/1 is
      # idempotent over an already merged list, so the resolved commands are
      # handed back in as the host's.
      conversation = conversation(state.conversation, snapshot)

      lines =
        snapshot.entries
        |> TranscriptPresentation.lines(opts.view)
        |> restore_question_rows(conversation.question)

      %{
        state
        | session: details.session,
          id: snapshot.id,
          # The file index belongs to the working directory being left.
          references:
            Map.merge(state.references, %{
              cwd: Map.get(snapshot, :cwd) || state.references.cwd,
              directory: nil,
              entries: [],
              refreshed_at: nil,
              index: nil,
              fuzzy: nil
            }),
          conversation: conversation,
          lines: Enum.reverse(lines),
          catalog: CatalogState.hydrate(state.catalog, details, snapshot.model, provider),
          elixir_mode?: Conversation.elixir_mode?(Map.get(snapshot, :tools, [])),
          resume: %{state.resume | busy?: false},
          command_index: 0,
          model_tab: "Automatic",
          command_tab: "Commands",
          command_menu?: true,
          scroll: 0,
          selection: nil,
          # The session's own inputs for up-arrow; what other sittings typed
          # stays where Ctrl-R finds it, with the file it is appended to.
          history: %{
            entries: remembered(snapshot.entries, opts.history_limit),
            index: nil,
            draft: nil,
            queued: [],
            queued_selected: 1,
            revising: nil,
            revising_original: nil,
            file: Map.get(state.history, :file),
            global: Map.get(state.history, :global, [])
          },
          # Call IDs belong to the session being left. A colliding ID in the
          # next session must never patch an old row.
          tools:
            Map.put(
              opts.empty_tools,
              :systemone,
              restore_systemone(snapshot.entries, opts.empty_tools.systemone)
            ),
          turn: opts.idle_turn
      }
    end

    defp restore_systemone(_entries, nil), do: nil

    defp restore_systemone(entries, systemone) do
      latest =
        entries
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{
            type: :extension_state,
            payload: %{"namespace" => "systemone_compaction", "value" => value}
          }
          when is_map(value) ->
            value

          _entry ->
            nil
        end)

      case latest do
        nil ->
          systemone

        value ->
          %{
            systemone
            | saved: value["last_saved_tokens_estimate"],
              outcome: value["last_outcome"]
          }
      end
    end

    defp conversation(previous, snapshot) do
      Conversation.new(
        model: snapshot.model,
        reasoning_effort: Map.get(snapshot, :reasoning_effort, "default"),
        commands: previous.commands
      )
      |> Conversation.restore_usage(snapshot.entries)
      |> Map.put(:context, snapshot.context)
      |> Map.put(
        :spent_usd,
        Map.get(snapshot, :inclusive_spent_usd, Map.get(snapshot, :spent_usd))
      )
      |> Map.put(:delegated_spent_usd, delegated_spend(snapshot))
      |> Map.put(:delegated_usage?, delegated_usage?(snapshot))
      |> Map.put(:busy?, snapshot.status == :busy)
      |> restore_question(Map.get(snapshot, :pending, []))
      |> restore_approvals(Map.get(snapshot, :pending, []))
    end

    # Up-arrow is rebuilt from durable user entries, newest first. The limit
    # comes from the editor that also caps history when a new prompt is sent.
    defp remembered(entries, limit) do
      entries
      |> Enum.reverse()
      |> Enum.filter(&(&1.type == :user))
      |> Enum.map(&Map.get(&1.payload, "text"))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.take(limit)
    end

    defp restore_question(conversation, pending) when is_list(pending) do
      case Enum.find(pending, &(Map.get(&1, :kind) == :question)) do
        %{call_id: call_id, payload: payload} when is_binary(call_id) and is_map(payload) ->
          question = payload |> Map.put_new(:call_id, call_id) |> Map.put_new(:options, [])
          %{conversation | asking: call_id, question: question}

        _none ->
          conversation
      end
    end

    defp restore_question(conversation, _pending), do: conversation

    defp restore_approvals(conversation, pending) when is_list(pending) do
      approvals =
        for %{kind: :approval, call_id: call_id, payload: payload} <- pending,
            is_binary(call_id) and is_map(payload) do
          %{
            call_id: call_id,
            name: field(payload, :name, "name", "tool"),
            arguments: field(payload, :arguments, "arguments", %{})
          }
        end

      %{conversation | approvals: approvals}
    end

    defp restore_approvals(conversation, _pending), do: conversation

    defp delegated_spend(snapshot) do
      case Map.get(snapshot, :usage) do
        %{delegated: usage} when is_map(usage) -> Map.get(usage, "cost_usd")
        _missing -> 0.0
      end
    end

    defp delegated_usage?(snapshot) do
      case Map.get(snapshot, :usage) do
        %{delegated: usage} when is_map(usage) ->
          Enum.any?(
            ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens),
            &(is_number(Map.get(usage, &1)) and Map.get(usage, &1) > 0)
          ) or Map.get(usage, "cost_usd") not in [0, 0.0]

        _missing ->
          false
      end
    end

    defp restore_question_rows(lines, nil), do: lines

    defp restore_question_rows(lines, %{ask_user: true}), do: lines

    defp restore_question_rows(lines, question) do
      id = Map.get(question, :call_id) || Map.get(question, "call_id") || "question"

      if Enum.any?(lines, &(ToolText.call_id(&1) == id)),
        do: lines,
        else: lines ++ ToolText.question_rows(question)
    end

    defp field(map, atom_key, string_key, default) do
      case Map.fetch(map, atom_key) do
        {:ok, value} -> value
        :error -> Map.get(map, string_key, default)
      end
    end
  end
end
