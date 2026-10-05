defmodule CaptureExtension.Signals do
  @moduledoc """
  Reads a transcript for the two signals that make a session worth a draft.

  This is a pure function over `Lemieux.Entry` lists, so it can be tested
  against hand-built transcripts and reused by the command hook, which sees
  the transcript only through the store. The signals:

    * **Verification failure** — a `bash` call whose command contains a
      configured verification pattern, whose result exited non-zero, with no
      later matching command in the session exiting zero. The last matching
      result decides: a failure that was followed by a passing rerun is a
      session that fixed itself, and a rerun after a pass that failed is a
      regression. Results that did not exit (a timeout, a background start)
      are neither a pass nor a failure and are ignored.

    * **Correction** — a user message, after at least one assistant turn,
      that opens with a configured correction pattern. The first prompt can
      never be one: `revert the last commit` is a task, not a complaint.

  Each signal names the entries that support it, because a feedback record
  must anchor on an entry id and a reviewer wants to find the moment in the
  transcript.
  """

  alias CaptureExtension.Config
  alias Lemieux.Entry

  @typedoc "One detected signal, with the transcript entries that support it."
  @type t :: %{
          kind: :verification_failure | :correction,
          pattern: String.t(),
          entry_ids: [String.t()],
          anchor_entry_id: String.t(),
          command: String.t() | nil,
          exit_status: integer() | nil,
          call_id: String.t() | nil,
          text: String.t() | nil
        }

  @doc "Detects signals over `entries`, verification failure first, then corrections in order."
  @spec detect(entries :: [Entry.t()], config :: Config.t()) :: [t()]
  def detect(entries, %Config{} = config) when is_list(entries) do
    state = %{calls: %{}, verifications: [], assistant?: false, corrections: []}
    final = Enum.reduce(entries, state, &observe(&1, &2, config))

    verification(final.verifications) ++ Enum.reverse(final.corrections)
  end

  defp observe(%Entry{type: :assistant, id: id, payload: payload}, state, config) do
    calls =
      payload
      |> Map.get("tool_calls", [])
      |> Enum.reduce(state.calls, fn call, calls ->
        case verification_call(call, config) do
          {:ok, call_id, command, pattern} ->
            Map.put(calls, call_id, %{
              command: command,
              pattern: pattern,
              assistant_entry_id: id
            })

          :skip ->
            calls
        end
      end)

    %{state | calls: calls, assistant?: true}
  end

  defp observe(%Entry{type: :tool_result, id: id, payload: payload}, state, _config) do
    with {:ok, call} <- Map.fetch(state.calls, Map.get(payload, "call_id")),
         %{"status" => "exited", "exit_status" => status} when is_integer(status) <-
           Map.get(payload, "structured_content") do
      result = %{
        call_id: payload["call_id"],
        command: call.command,
        pattern: call.pattern,
        exit_status: status,
        entry_ids: [call.assistant_entry_id, id],
        anchor_entry_id: id
      }

      %{state | verifications: [result | state.verifications]}
    else
      _not_a_verification_exit -> state
    end
  end

  defp observe(%Entry{type: :user, id: id, payload: %{"text" => text}}, state, config)
       when is_binary(text) do
    with true <- state.assistant?,
         {:ok, pattern} <- correction_pattern(text, config) do
      correction = %{
        kind: :correction,
        pattern: pattern,
        entry_ids: [id],
        anchor_entry_id: id,
        command: nil,
        exit_status: nil,
        call_id: nil,
        text: String.trim(text)
      }

      %{state | corrections: [correction | state.corrections]}
    else
      _not_a_correction -> state
    end
  end

  defp observe(_entry, state, _config), do: state

  defp verification_call(%{"name" => "bash", "id" => call_id, "arguments" => arguments}, config)
       when is_binary(call_id) and is_map(arguments) do
    case Map.get(arguments, "command") do
      command when is_binary(command) ->
        case match(config.verification_regexes, command) do
          {:ok, pattern} -> {:ok, call_id, command, pattern}
          :error -> :skip
        end

      _other ->
        :skip
    end
  end

  defp verification_call(_call, _config), do: :skip

  defp correction_pattern(text, config), do: match(config.correction_regexes, text)

  defp match(regexes, text) do
    Enum.find_value(regexes, :error, fn {pattern, regex} ->
      if Regex.match?(regex, text), do: {:ok, pattern}
    end)
  end

  # `verifications` is newest first; only its head can be the last matching
  # result, and only a non-zero exit there is a signal.
  defp verification([%{exit_status: status} = last | _earlier]) when status != 0 do
    [
      %{
        kind: :verification_failure,
        pattern: last.pattern,
        entry_ids: last.entry_ids,
        anchor_entry_id: last.anchor_entry_id,
        command: last.command,
        exit_status: status,
        call_id: last.call_id,
        text: nil
      }
    ]
  end

  defp verification(_verifications), do: []
end
