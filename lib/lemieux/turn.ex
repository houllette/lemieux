defmodule Lemieux.Turn do
  @moduledoc """
  The rules of one model request, as a pure fold.

  A turn is fed `Lemieux.Provider` events one at a time and answers with
  *effects* — what to show a subscriber, what to persist, when the turn is
  over. It performs none of them. It starts no processes, touches no files,
  reads no clock, and mints no ids. The session supplies the id of the
  assistant entry this turn may eventually append, which lets streaming
  events name their durable destination before it exists.

  ## Why the loop's rules live outside the loop's process

  The interesting questions about an agent turn are all questions about
  sequence: what happens when the stream dies halfway, whether usage lands on
  the entry it belongs to, what a second terminal event means. Answered inside
  a `GenServer`, each of those becomes a test that starts a process, drives it
  with messages and waits for something to arrive — so a broken rule shows up
  as a timeout, in a test that is slow enough to be run less often. Answered
  here, the same question is a list in and a list out.

  `Lemieux.Session` is the other half: it owns the process, the store and the
  clock, and it does what the effects say. The split is worth keeping — the
  moment a rule migrates into `handle_info/2` it stops being testable this
  way.

  ## Effects

    * `{:emit, event}` — show this to the session's subscribers now.
    * `{:append, {type, payload, usage}}` — persist an entry. The turn cannot
      build a `Lemieux.Entry` itself: that needs an id and a clock.
    * `{:run_tools, calls}` — the model asked for tools. The session runs them
      and starts another turn with the results.
    * `{:finished, stop_reason}` — the provider is done. Always last, and
      emitted exactly once.

  Exactly one of `{:run_tools, _}` and `{:finished, _}` ends a turn, which is
  what makes "is this conversation over?" a question with one answer. A turn
  that called tools is not finished — the model is mid-thought — and a turn
  that finished will not call anything.

  ## Content, and who assembles it

  Deltas are assembled into content as a fallback so a stream that dies
  halfway still persists what the user watched arrive. When the provider
  sends an assembled `{:message, payload}` that payload wins outright, because
  it is the one that carries what the deltas cannot — a signature on a
  thinking block, a tool call's arguments as the provider parsed them — and
  it is what the next request has to send back. The fallback's ordering
  (thinking, then text) is a guess; the assembled message is the truth.
  """

  alias Lemieux.Provider.Error, as: ProviderError

  @type stop_reason :: atom()

  @typedoc "An entry for the session to persist: type, payload, usage."
  @type entry_spec :: {Lemieux.Entry.type(), map(), map() | nil}

  @type effect ::
          {:emit, term()}
          | {:append, entry_spec()}
          | {:run_tools, [Lemieux.Provider.tool_call()]}
          | {:finished, stop_reason()}

  @typedoc """
  The tool call the model is composing right now, as far as it has got.

  `head` is the first bytes of its arguments — enough to hold a path or a
  command — and `bytes` is how much has arrived. Neither is persisted: the
  assembled call in the message is the record, and this is what a front end
  draws while waiting for it.
  """
  @type composing :: %{
          index: non_neg_integer() | nil,
          name: String.t() | nil,
          bytes: non_neg_integer(),
          head: String.t()
        }

  @type t :: %__MODULE__{
          entry_id: String.t(),
          status: :streaming | :done,
          text: [String.t()],
          thinking: [String.t()],
          tool_calls: [Lemieux.Provider.tool_call()],
          composing: composing() | nil,
          message: map() | nil,
          usage: map() | nil,
          stop_reason: stop_reason() | nil
        }

  @enforce_keys [:entry_id]
  defstruct entry_id: nil,
            status: :streaming,
            text: [],
            thinking: [],
            tool_calls: [],
            composing: nil,
            message: nil,
            usage: nil,
            stop_reason: nil

  # How much of a composing call's arguments a front end is shown. A `write`
  # puts its path before its content and a `bash` its command first, so this
  # is enough to say *what* is being written without carrying the file.
  @head_bytes 240

  @doc """
  Starts a turn, before any provider event has arrived.
  """
  @spec new(entry_id :: String.t()) :: t()
  def new(entry_id) when is_binary(entry_id), do: %__MODULE__{entry_id: entry_id}

  @doc """
  Returns partial assistant content worth preserving when a request is cancelled.

  Tool calls are deliberately omitted: until the provider ends the turn they
  are an unfinished stream fragment, and persisting one without executing or
  answering it creates a conversation every provider rejects on resume.
  """
  @spec checkpoint(turn :: t()) :: entry_spec() | nil
  def checkpoint(%__MODULE__{} = turn) do
    case assistant(turn) do
      [{:append, {:assistant, payload, usage}}] ->
        payload = Map.delete(payload, "tool_calls")
        if Map.get(payload, "content", []) == [], do: nil, else: {:assistant, payload, usage}

      [] ->
        nil
    end
  end

  @doc "Whether the provider has emitted any semantic response for this turn."
  @spec progressed?(turn :: t()) :: boolean()
  def progressed?(%__MODULE__{} = turn) do
    turn.text != [] or turn.thinking != [] or turn.tool_calls != [] or is_map(turn.message) or
      is_map(turn.composing)
  end

  @doc """
  Folds one provider event into the turn, returning the effects it causes.
  """
  @spec step(turn :: t(), event :: Lemieux.Provider.event()) :: {t(), [effect()]}
  def step(turn, event)

  # A stream that keeps talking after its terminal event is a provider bug,
  # and the damage it could do — a second assistant entry, a second
  # :finished, a session that never idles — is worse than the lost delta.
  def step(%__MODULE__{status: :done} = turn, _event), do: {turn, []}

  def step(%__MODULE__{} = turn, {:text_delta, text}) when is_binary(text) do
    event = {:text_delta, %{id: turn.entry_id, text: text}}
    {%{turn | text: [text | turn.text]}, [{:emit, event}]}
  end

  def step(%__MODULE__{} = turn, {:thinking_delta, text}) when is_binary(text) do
    event = {:thinking_delta, %{id: turn.entry_id, text: text}}
    {%{turn | thinking: [text | turn.thinking]}, [{:emit, event}]}
  end

  def step(%__MODULE__{} = turn, {:tool_call, call}) when is_map(call) do
    call = Map.put_new(call, :arguments, %{})

    {%{turn | tool_calls: [call | turn.tool_calls]}, [{:emit, {:tool_call, call}}]}
  end

  # A name opens a call (or a new one, when the index moves on); a fragment
  # grows the current one. The emitted event carries the whole picture each
  # time, so a front end keeps no state of its own about it.
  def step(%__MODULE__{} = turn, {:tool_call_delta, delta}) when is_map(delta) do
    composing = compose(turn.composing, delta)

    event =
      {:tool_call_delta,
       %{id: turn.entry_id, name: composing.name, bytes: composing.bytes, head: composing.head}}

    {%{turn | composing: composing}, [{:emit, event}]}
  end

  def step(%__MODULE__{} = turn, {:message, payload}) when is_map(payload) do
    {%{turn | message: payload}, []}
  end

  def step(%__MODULE__{} = turn, {:usage, usage}) when is_map(usage) do
    {%{turn | usage: usage}, [{:emit, {:usage, usage}}]}
  end

  def step(%__MODULE__{} = turn, {:done, stop_reason}) when is_atom(stop_reason) do
    turn = %{turn | status: :done, stop_reason: stop_reason}

    {turn, assistant(turn) ++ [ending(turn, stop_reason)]}
  end

  # What was said survives the error; the calls do not. A call announced before
  # the stream died was never run and never will be — the turn is ending — and
  # an assistant entry carrying it is a request no provider accepts back: every
  # call needs an answer. The transcript used to keep them, which left a live
  # session holding unanswered calls until something happened to resume it.
  # `checkpoint/1` already made this choice for a cancelled turn.
  #
  # The text is marked `"partial"`: it is a record of what a person watched
  # arrive, and a request that sent it back would ask the model to continue a
  # sentence as though it were its own finished answer — which Anthropic treats
  # as a prefill, and refuses outright when the model was thinking.
  def step(%__MODULE__{} = turn, {:error, reason}) do
    finished = %{turn | status: :done, stop_reason: :error}

    effects =
      partial(turn) ++
        [
          {:emit, {:error, reason}},
          {:append, {:error, error_payload(reason), nil}},
          {:finished, :error}
        ]

    {finished, effects}
  end

  # The category travels with the message because prose cannot be classified after
  # the fact. Every provider failure ends a turn the same way — stop reason
  # `:error`, one error entry — so a reader of the transcript alone cannot tell a
  # mid-stream timeout from a refused request, and the evaluation lane needs exactly
  # that distinction. `category/1` reads typed provider fields, never the message it
  # also produces.
  #
  # The HTTP status travels too, when there was one. A category is policy, and
  # the fact behind it is sometimes what a host's own policy needs: a CDN that
  # answers a streaming POST with a bare 414 is `:other` by status, and a host
  # that has seen that CDN do it may still want to retry once — which it cannot
  # decide from "other" and a sentence.
  #
  # So does the provider's own code, when it gave one: `"cyber_policy"` says
  # which refusal a `"refused"` was, where the sentence is whatever the
  # provider chose to write (#32).
  defp error_payload(reason) do
    %{
      "reason" => ProviderError.message(reason),
      "category" => Atom.to_string(ProviderError.category(reason))
    }
    |> put_present("http_status", ProviderError.http_status(reason))
    |> put_present("code", ProviderError.code(reason))
  end

  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

  defp partial(turn) do
    case checkpoint(turn) do
      nil -> []
      {:assistant, payload, usage} -> [{:append, {:assistant, partial_payload(payload), usage}}]
    end
  end

  @doc """
  Marks an assistant payload as a partial answer kept only as a record.

  `Lemieux.Compaction.partial?/1` is how a request builder recognises one.
  """
  @spec partial_payload(payload :: map()) :: map()
  def partial_payload(payload) when is_map(payload), do: Map.put(payload, "partial", true)

  # A model's stop reason is advice, not instruction: providers disagree about
  # whether a turn with both text and a tool call is `:tool_calls` or `:stop`,
  # and one of them is occasionally wrong. What decides is whether there is
  # anything to run.
  #
  # With one exception, which is a fact rather than advice: `:length` says the
  # output limit ended the response, wherever it fell. A model writing a large
  # file is inside its last call's arguments when that happens, and the call
  # arrives with arguments that did not decode, or with none. Run as it stood,
  # `write` answered "needs a path and content", the model sent the same
  # oversized call again, and the repeat guard ended the prompt (live,
  # 2026-10-07). Marked, the call is answered with what happened and not run
  # (`Lemieux.Tools.run/5`). A last call whose arguments arrived whole runs:
  # the cut came after it.
  defp ending(%__MODULE__{tool_calls: []}, stop_reason), do: {:finished, stop_reason}
  defp ending(%__MODULE__{} = turn, :length), do: {:run_tools, turn |> calls() |> cut_off_last()}
  defp ending(%__MODULE__{} = turn, _stop_reason), do: {:run_tools, calls(turn)}

  defp calls(%__MODULE__{tool_calls: calls}), do: Enum.reverse(calls)

  defp cut_off_last(calls) do
    {last, earlier} = List.pop_at(calls, -1)

    if cut_off?(last),
      do: earlier ++ [Map.put(last, :argument_error, :output_limit)],
      else: calls
  end

  defp cut_off?(%{argument_error: _reason}), do: true
  defp cut_off?(call), do: Map.get(call, :arguments, %{}) == %{}

  defp assistant(%__MODULE__{message: payload, usage: usage} = turn) when is_map(payload) do
    payload =
      case {Map.get(payload, "content", []), content(turn)} do
        {[], streamed} when streamed != [] -> Map.put(payload, "content", streamed)
        {_assembled, _streamed} -> payload
      end

    [{:append, {:assistant, with_calls(payload, turn), usage}}]
  end

  defp assistant(%__MODULE__{} = turn) do
    case {content(turn), turn.tool_calls} do
      {[], []} ->
        []

      {content, _calls} ->
        [{:append, {:assistant, with_calls(%{"content" => content}, turn), turn.usage}}]
    end
  end

  defp compose(current, delta) do
    current
    |> same_call_or_next(Map.get(delta, :index), Map.get(delta, :name))
    |> named(Map.get(delta, :name), Map.get(delta, :index))
    |> grown(Map.get(delta, :fragment))
  end

  # A different index, or a fresh name with no index at all, is the next
  # call; the same index (or none) with only a fragment is this one.
  defp same_call_or_next(%{index: seen} = current, index, _name)
       when is_integer(index) and index == seen,
       do: current

  defp same_call_or_next(%{} = current, nil, nil), do: current

  defp same_call_or_next(_current, index, name),
    do: %{index: index, name: name, bytes: 0, head: ""}

  defp named(call, nil, _index), do: call
  defp named(call, name, index), do: %{call | name: name, index: index || call.index}

  defp grown(call, nil), do: call

  defp grown(call, fragment),
    do: %{call | bytes: call.bytes + byte_size(fragment), head: head(call.head, fragment)}

  defp head(head, _fragment) when byte_size(head) >= @head_bytes, do: head

  defp head(head, fragment) do
    room = @head_bytes - byte_size(head)
    taken = if byte_size(fragment) > room, do: binary_part(fragment, 0, room), else: fragment
    head <> if(String.valid?(taken), do: taken, else: String.replace_invalid(taken))
  end

  defp with_calls(payload, %__MODULE__{tool_calls: []}), do: payload

  defp with_calls(payload, %__MODULE__{} = turn) do
    calls =
      turn
      |> calls()
      |> Enum.map(
        &%{"id" => &1.id, "name" => &1.name, "arguments" => Map.get(&1, :arguments, %{})}
      )

    Map.put(payload, "tool_calls", calls)
  end

  defp content(%__MODULE__{} = turn) do
    part("thinking", turn.thinking) ++ part("text", turn.text)
  end

  defp part(_type, []), do: []

  defp part(type, chunks) do
    [%{"type" => type, "text" => chunks |> Enum.reverse() |> IO.iodata_to_binary()}]
  end
end
