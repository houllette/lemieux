defmodule Lemieux.Progress do
  @moduledoc """
  Whether a piece of delegated work is still going somewhere.

  A deadline used to be the answer to "how long may a child run": two
  minutes by definition, three for the group, and a child that reached
  either was cancelled and reported as a timeout. That was a spend guard
  wearing a loop guard's clothes, and it failed in the direction that costs
  the most. A session on 2026-09-18 sent three repository scouts to a
  capable model; each made a distinct `read` every two or three seconds
  for thirty turns, began streaming a complete answer, and was killed at
  exactly 120.0 s with the answer half written. The parent received "no
  findings" for roughly 800k tokens of correct work. Nothing about those
  children was stuck. The clock could not tell.

  What actually bounds a runaway is already in place: dollars or requests
  bound spend, `Lemieux.Session` stops a child that asks for the same thing
  three rounds running, and a tool has its own deadline. The wall clock only
  bounds *waiting*. So `Lemieux.Subagent.Group` now treats a child's interval
  as a soft deadline: when it elapses the child is **assessed**, and a child
  that is progressing simply gets another interval, up to the hard ceiling
  the host set.

  ## Two tiers, because the cheap one is usually enough

  `assess/2` reads the entries a child appended since its last check and
  decides the clear cases without spending a request:

    * **repeating** — half or more of the interval's calls repeated an
      earlier call *and got the same answer*. That is the session's own
      no-progress rule widened to a window, so it also catches the
      alternating loop (`a, b, a, b, …`) that identical-wave detection
      cannot. Verdict: stalled.
    * **waiting** — nothing was appended, but a provider request or a tool
      call is in flight. A test suite that has run for twenty minutes is
      waiting, not stuck; the provider's quiet timeout and the tool's own
      deadline are the clocks for that. Verdict: progressing.
    * **idle** — nothing appended and nothing in flight, which a running
      session should never be. Verdict: stalled.

  Everything else — distinct calls that may or may not be going anywhere —
  is the case a person would need to read the transcript to decide, and the
  model reads it instead. `judge/2` sends the objective, the elapsed time
  and the interval's calls to a model and asks for one word and a reason.
  It is told to prefer "progressing" when unsure, because the two mistakes
  are not symmetric: a stalled child that runs one more interval costs an
  interval, while a progressing child that is killed loses everything it did.

  ## The assessment fails open

  A judge that errors, times out or answers unreadably yields *progressing*,
  with `by: :error` so the outcome is visible. The alternative — treating an
  unanswered question as a stall — would kill working children whenever the
  assessor's provider had a bad minute, which is exactly the failure this
  module exists to stop. The host's hard deadline and the child's budgets
  still bound a child the assessor keeps misreading.

  `assess/2` is pure apart from the judge call, and `evidence/2` is pure,
  so a host can run either against a transcript it has read back.
  """

  alias Lemieux.Clock
  alias Lemieux.Entry
  alias Lemieux.Provider
  alias Lemieux.Request

  defmodule Evidence do
    @moduledoc "What one check saw: the interval's new entries and the clocks around them."

    @typedoc "One tool call and what came back, as the child's transcript recorded it."
    @type call :: %{
            name: String.t(),
            arguments: map(),
            output: String.t(),
            error?: boolean(),
            at: DateTime.t()
          }

    @typedoc "The thing the child is currently blocked on, if the transcript shows one."
    @type in_flight :: %{
            kind: :request | :tool,
            name: String.t() | nil,
            since_ms: non_neg_integer()
          }

    @type t :: %__MODULE__{
            subject: map(),
            elapsed_ms: non_neg_integer(),
            interval_ms: pos_integer(),
            checks: non_neg_integer(),
            turns: non_neg_integer(),
            entries: [Entry.t()],
            calls: [call()],
            in_flight: in_flight() | nil,
            last_seq: non_neg_integer() | nil
          }

    defstruct subject: %{},
              elapsed_ms: 0,
              interval_ms: 1,
              checks: 0,
              turns: 0,
              entries: [],
              calls: [],
              in_flight: nil,
              last_seq: nil
  end

  defmodule Verdict do
    @moduledoc "What a check concluded, and who concluded it."

    @type outcome :: :progressing | :stalled
    @typedoc """
    `:activity` for the transcript rules, `:model` for the judge, `:host` for
    a host-supplied assessor, `:error` when the judge could not answer and
    the check fell open.
    """
    @type by :: :activity | :model | :host | :error

    @type t :: %__MODULE__{
            outcome: outcome(),
            by: by(),
            note: String.t(),
            usage: map() | nil
          }

    @enforce_keys [:outcome, :by, :note]
    defstruct [:outcome, :by, :note, usage: nil]
  end

  # A window this small cannot say much. Six is two rounds of a three-call
  # cycle, or three of a two-call one — enough to be a pattern and not a
  # retry.
  @repeat_floor 6

  # How many of the interval's calls the judge is shown. The most recent
  # ones say the most about where the child is going; the count of what was
  # left out is stated so the judge knows it is looking at a tail.
  @shown_calls 24
  @argument_bytes 160
  @output_bytes 120

  @default_judge_timeout :timer.seconds(60)
  # Enough for a reasoning model to think and still answer: `max_tokens`
  # becomes the completion cap on those routes and reasoning spends it first,
  # which is how an 8k child cap once truncated scouts before they answered.
  @judge_max_tokens 4_000

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ~w(verdict reason),
    "properties" => %{
      "verdict" => %{"type" => "string", "enum" => ~w(progressing stalled)},
      "reason" => %{"type" => "string"}
    }
  }

  @system """
  You are watching a delegated coding-agent child on behalf of its
  coordinator. From its recent activity, decide whether it is still making
  progress toward its objective or has stopped making progress.

  A child that is reading new, relevant material, narrowing in on an
  answer, or waiting on something it started is progressing. A child that
  keeps re-reading the same material, wanders without a direction, or cycles
  through the same few actions is stalled.

  Prefer "progressing" when unsure. The two mistakes are not equal: a
  stalled child allowed to continue costs one more interval, while a
  progressing child that is stopped loses everything it has done.

  Answer with a JSON object: {"verdict": "progressing" | "stalled", "reason": "one sentence"}.
  """

  @doc """
  Builds the evidence for one check from a child's transcript.

  `entries` is the whole transcript, oldest first; only those after
  `:since_seq` count as the interval's activity, so the same list read at
  each check yields each check's own window. `:now` is the clock the
  in-flight age is measured against and defaults to the current time.

  Options: `:since_seq`, `:elapsed_ms`, `:interval_ms`, `:checks`,
  `:subject`, `:now`.
  """
  @spec evidence(entries :: [Entry.t()], opts :: keyword()) :: Evidence.t()
  def evidence(entries, opts \\ []) when is_list(entries) and is_list(opts) do
    since = Keyword.get(opts, :since_seq)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    fresh = Enum.filter(entries, &(is_nil(since) or &1.seq > since))

    %Evidence{
      subject: Keyword.get(opts, :subject, %{}),
      elapsed_ms: Keyword.get(opts, :elapsed_ms, 0),
      interval_ms: Keyword.get(opts, :interval_ms, 1),
      checks: Keyword.get(opts, :checks, 0),
      turns: Enum.count(entries, &(&1.type == :request)),
      entries: fresh,
      calls: fresh |> Enum.filter(&(&1.type == :tool_result)) |> Enum.map(&call/1),
      in_flight: in_flight(entries, now),
      last_seq: entries |> List.last() |> then(&(&1 && &1.seq))
    }
  end

  @doc """
  Decides whether the child the evidence describes is still progressing.

  The transcript rules decide first. When they cannot, `:assess` says who
  does: `:model` (the default) asks `judge/2` with `:provider`, `:model` and
  `:timeout_ms`; `:activity` calls distinct activity progress without asking
  anyone; a one-argument function receives the evidence and answers for the
  host, with a `%Verdict{}`, `{:progressing, note}` or `{:stalled, note}`.
  """
  @spec assess(evidence :: Evidence.t(), opts :: keyword()) :: Verdict.t()
  def assess(%Evidence{} = evidence, opts \\ []) when is_list(opts) do
    case activity(evidence) do
      %Verdict{} = verdict ->
        verdict

      {:inconclusive, note} ->
        inconclusive(evidence, note, Keyword.get(opts, :assess, :model), opts)
    end
  end

  @doc """
  Whether the calls in a window are mostly repeats of earlier ones.

  A call repeats when its name, arguments *and* output match an earlier
  call's: asking again after an edit is not a repeat, because the answer
  changed. Needs #{@repeat_floor} calls before it will say so, and says so
  when the repeats are at least half of them. Public because
  `Lemieux.Session` applies the same rule to its own recent calls.
  """
  @spec repeating?(calls :: [Evidence.call() | map()]) :: boolean()
  def repeating?(calls) when is_list(calls) do
    {total, repeated} = repeats(calls)

    total >= @repeat_floor and repeated * 2 >= total
  end

  @doc """
  Asks a model whether the child is progressing.

  Runs one bounded request against `:provider` and `:model`, collecting the
  answer and its usage; `:timeout_ms` (default one minute) ends a request
  that does not answer, measured on `:clock` (a `Lemieux.Clock`, the real
  one when omitted). Never raises: a provider failure, a timeout or an
  unreadable answer is `{:error, reason}`, and `assess/2` turns that into a
  fail-open verdict.
  """
  @spec judge(evidence :: Evidence.t(), opts :: keyword()) ::
          {:ok, Verdict.t()} | {:error, term()}
  def judge(%Evidence{} = evidence, opts) when is_list(opts) do
    with {:ok, provider} <- fetch(opts, :provider),
         {:ok, model} <- fetch(opts, :model) do
      timeout = Keyword.get(opts, :timeout_ms, @default_judge_timeout)
      request = request(model, evidence)
      me = self()
      reference = make_ref()

      # The task is linked to this process, so a provider that raises would
      # take the check down with it — and a check that dies is a child left
      # without a clock. This is a boundary: the failure is returned as the
      # answer, not swallowed.
      task = Task.async(fn -> run_judge(provider, request, me, reference) end)

      # The timeout is a clock timer rather than `Task.yield/2`'s own wait, so
      # a test can end the question by moving a manual clock instead of by
      # waiting out real milliseconds.
      clock = Keyword.get(opts, :clock)
      timer = Clock.send_after(clock, me, {:judge_timeout, reference}, timeout)
      outcome = await_judge(task, reference)
      Clock.cancel(clock, timer)
      flush_timeout(reference)

      case outcome do
        {:ok, :ok} -> reference |> collect(%{text: "", message: nil, usage: nil}) |> decode()
        {:ok, {:error, reason}} -> drain(reference, {:error, reason})
        {:exit, reason} -> drain(reference, {:error, {:judge_crashed, reason}})
        nil -> drain(reference, {:error, :judge_timeout})
      end
    end
  end

  # `Task.yield/2`'s answers, from the messages `Task.async/1` documents: the
  # task's reply, its exit, or — when the timer comes first — whatever
  # `Task.shutdown/2` finds, which may still be a reply that raced the timer.
  defp await_judge(%Task{ref: ref} = task, reference) do
    receive do
      {^ref, reply} ->
        # `Task.ignore/1` rather than demonitoring the ref by hand: the ref is
        # opaque, and ignore both demonitors and flushes the DOWN message.
        _ignored = Task.ignore(task)
        {:ok, reply}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:exit, reason}

      {:judge_timeout, ^reference} ->
        Task.shutdown(task, :brutal_kill)
    end
  end

  # A timer that fired just as the answer arrived was not cancelled in time;
  # its message must not be left for the next question this process asks.
  defp flush_timeout(reference) do
    receive do
      {:judge_timeout, ^reference} -> :ok
    after
      0 -> :ok
    end
  end

  # Runs inside the judge task, which is linked to the check: a provider that
  # raised would take the check down with it, and a check that dies is a
  # child left without a clock. This is a boundary, and the failure comes
  # back as the answer rather than being swallowed.
  defp run_judge(provider, request, me, reference) do
    Provider.run(provider, request, &send(me, {reference, &1}))
  rescue
    error -> {:error, {:judge_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:judge_raised, {kind, reason}}}
  end

  @doc "Renders the evidence as the judge sees it. Public so a host can log it."
  @spec describe(evidence :: Evidence.t()) :: String.t()
  def describe(%Evidence{} = evidence) do
    shown = Enum.take(evidence.calls, -@shown_calls)
    omitted = length(evidence.calls) - length(shown)

    [
      "Objective: #{Map.get(evidence.subject, :objective) || "(not stated)"}",
      "Elapsed: #{duration(evidence.elapsed_ms)}; this is check #{evidence.checks + 1}, " <>
        "each covering #{duration(evidence.interval_ms)}. Model requests so far: #{evidence.turns}.",
      in_flight_line(evidence.in_flight),
      calls_heading(evidence.calls, shown, omitted)
    ]
    |> Enum.concat(numbered(shown))
    |> Enum.concat(other_lines(evidence.entries))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # -- the transcript rules ---------------------------------------------------

  defp activity(%Evidence{calls: calls} = evidence) do
    {total, repeated} = repeats(calls)

    cond do
      repeating?(calls) ->
        %Verdict{
          outcome: :stalled,
          by: :activity,
          note:
            "#{repeated} of the last #{total} calls repeated an earlier call " <>
              "and got the same answer"
        }

      evidence.entries == [] and is_map(evidence.in_flight) ->
        %Verdict{
          outcome: :progressing,
          by: :activity,
          note: "waiting on " <> waiting_on(evidence.in_flight)
        }

      evidence.entries == [] ->
        %Verdict{
          outcome: :stalled,
          by: :activity,
          note: "nothing happened for #{duration(evidence.interval_ms)}"
        }

      true ->
        {:inconclusive,
         "#{total - repeated} distinct calls in the last #{duration(evidence.interval_ms)}"}
    end
  end

  defp inconclusive(_evidence, note, :activity, _opts),
    do: %Verdict{outcome: :progressing, by: :activity, note: note}

  defp inconclusive(evidence, note, :model, opts) do
    case judge(evidence, opts) do
      {:ok, verdict} ->
        verdict

      {:error, reason} ->
        %Verdict{
          outcome: :progressing,
          by: :error,
          note: "#{note}; the assessment failed (#{describe_error(reason)}) and fell open"
        }
    end
  end

  defp inconclusive(evidence, _note, assess, _opts) when is_function(assess, 1),
    do: evidence |> assess.() |> host_verdict()

  defp host_verdict(%Verdict{} = verdict), do: %{verdict | by: :host}

  defp host_verdict({outcome, note}) when outcome in [:progressing, :stalled] and is_binary(note),
    do: %Verdict{outcome: outcome, by: :host, note: note}

  defp host_verdict(outcome) when outcome in [:progressing, :stalled],
    do: %Verdict{outcome: outcome, by: :host, note: "the host said so"}

  defp host_verdict(other),
    do: %Verdict{outcome: :progressing, by: :error, note: "the host answered #{inspect(other)}"}

  defp repeats(calls) do
    fingerprints = Enum.map(calls, &fingerprint/1)
    total = length(fingerprints)
    {total, total - length(Enum.uniq(fingerprints))}
  end

  # The same fingerprint `Lemieux.Session` gives a wave: what was asked and
  # what came back, so a re-run after an edit is new information and an
  # identical one is not.
  defp fingerprint(call) do
    :erlang.phash2(
      {field(call, :name), field(call, :arguments), field(call, :output), field(call, :error?)}
    )
  end

  defp field(call, :error?), do: Map.get(call, :error?, Map.get(call, "error", false))
  defp field(call, key), do: Map.get(call, key, Map.get(call, Atom.to_string(key)))

  defp call(%Entry{payload: payload, at: at}) do
    %{
      name: payload["name"] || "tool",
      arguments: payload["arguments"] || %{},
      output: payload["output"] || "",
      error?: payload["error"] == true,
      at: at
    }
  end

  # What the transcript's tail says the session is doing now. A request entry is
  # written when the provider is asked and an assistant entry when it answers, so a
  # trailing request is a request in flight; a trailing assistant entry with tool
  # calls, or a trailing tool result, is a wave of tools still running.
  defp in_flight(entries, now) do
    case List.last(entries) do
      %Entry{type: :request, at: at} ->
        %{kind: :request, name: nil, since_ms: age(now, at)}

      %Entry{type: :assistant, payload: %{"tool_calls" => [_ | _] = calls}, at: at} ->
        %{
          kind: :tool,
          name: Enum.map_join(calls, ", ", &(&1["name"] || "tool")),
          since_ms: age(now, at)
        }

      %Entry{type: :tool_result, at: at} = last ->
        %{kind: :tool, name: outstanding(entries, last), since_ms: age(now, at)}

      _other ->
        nil
    end
  end

  # The wave's calls that have no result yet, named so the judge can see
  # what the child is waiting on.
  defp outstanding(entries, last) do
    entries
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :assistant))
    |> case do
      %Entry{payload: %{"tool_calls" => calls}} when is_list(calls) ->
        done =
          entries
          |> Enum.filter(&(&1.type == :tool_result))
          |> MapSet.new(& &1.payload["call_id"])

        calls
        |> Enum.reject(&MapSet.member?(done, &1["id"]))
        |> Enum.map_join(", ", &(&1["name"] || "tool"))
        |> case do
          "" -> last.payload["name"]
          names -> names
        end

      _none ->
        last.payload["name"]
    end
  end

  defp age(now, at), do: now |> DateTime.diff(at, :millisecond) |> max(0)

  # -- the judge --------------------------------------------------------------

  defp request(model, evidence) do
    Request.new(model,
      system: @system,
      entries: [Entry.new(:user, %{"text" => describe(evidence)}, seq: 1)],
      output_schema: @schema,
      params: [max_tokens: @judge_max_tokens]
    )
  end

  defp collect(reference, acc) do
    receive do
      {^reference, {:text_delta, text}} -> collect(reference, %{acc | text: acc.text <> text})
      {^reference, {:message, message}} -> collect(reference, %{acc | message: message})
      {^reference, {:usage, usage}} -> collect(reference, %{acc | usage: usage})
      {^reference, _event} -> collect(reference, acc)
    after
      0 -> acc
    end
  end

  # The task is dead, but its events may still be in the mailbox; a later
  # judge call must not read this one's answer.
  defp drain(reference, result) do
    receive do
      {^reference, _event} -> drain(reference, result)
    after
      0 -> result
    end
  end

  defp decode(%{text: text, message: message, usage: usage}) do
    answer = message_text(message) || text

    with {:ok, outcome, reason} <- verdict(answer) do
      {:ok, %Verdict{outcome: outcome, by: :model, note: reason, usage: usage}}
    end
  end

  defp message_text(%{"content" => content}) when is_list(content) do
    case Enum.map_join(content, "", &Map.get(&1, "text", "")) do
      "" -> nil
      text -> text
    end
  end

  defp message_text(_message), do: nil

  # Read the way `Lemieux.Subagent.Result` reads a child's body: a fence is
  # unwrapped, and a model that answered in words rather than JSON still
  # answered, as long as it used exactly one of the two words it was given.
  defp verdict(text) when is_binary(text) do
    trimmed = unfence(text)

    case JSON.decode(trimmed) do
      {:ok, %{"verdict" => verdict} = object} when verdict in ~w(progressing stalled) ->
        {:ok, String.to_existing_atom(verdict), reason(object["reason"], verdict)}

      _not_json ->
        worded(String.downcase(trimmed))
    end
  end

  defp verdict(_text), do: {:error, :unreadable_verdict}

  defp worded(text) do
    case {String.contains?(text, "stalled"), String.contains?(text, "progressing")} do
      {true, false} -> {:ok, :stalled, reason(text, "stalled")}
      {false, true} -> {:ok, :progressing, reason(text, "progressing")}
      _ambiguous -> {:error, :unreadable_verdict}
    end
  end

  defp reason(reason, _verdict) when is_binary(reason) and reason != "",
    do: reason |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 400)

  defp reason(_reason, verdict), do: "the assessor said #{verdict}"

  defp unfence(text) do
    trimmed = String.trim(text)

    case Regex.run(~r/\A```[a-zA-Z0-9_-]*\s*\n(.*?)\n?```\z/s, trimmed) do
      [_whole, inner] -> String.trim(inner)
      _unfenced -> trimmed
    end
  end

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _missing -> {:error, {:missing_option, key}}
    end
  end

  # -- rendering --------------------------------------------------------------

  defp in_flight_line(nil), do: "In flight: nothing"
  defp in_flight_line(in_flight), do: "In flight: " <> waiting_on(in_flight)

  defp waiting_on(%{kind: :request, since_ms: since}),
    do: "a provider request for #{duration(since)}"

  defp waiting_on(%{kind: :tool, name: name, since_ms: since}),
    do: "the #{name} tool for #{duration(since)}"

  defp calls_heading([], _shown, _omitted), do: "Calls in this interval: none"

  defp calls_heading(calls, shown, 0),
    do: "Calls in this interval (oldest first), all #{length(calls)}:" |> singular(shown)

  defp calls_heading(calls, shown, omitted),
    do:
      "Calls in this interval, the last #{length(shown)} of #{length(calls)} (#{omitted} earlier omitted):"

  defp singular(heading, [_one]), do: String.replace(heading, "all 1:", "1:")
  defp singular(heading, _shown), do: heading

  defp numbered(calls) do
    calls
    |> Enum.with_index(1)
    |> Enum.map(fn {call, index} ->
      marker = if call.error?, do: " (error)", else: ""

      "  #{index}. #{call.name} #{clip(JSON.encode!(call.arguments), @argument_bytes)}#{marker} " <>
        "→ #{clip(call.output, @output_bytes)}"
    end)
  end

  # The non-tool entries worth a line: a provider error, a compaction, and
  # text the child wrote between calls. Requests, snapshots and results are
  # already accounted for above.
  defp other_lines(entries) do
    entries
    |> Enum.flat_map(fn
      %Entry{type: :error, payload: %{"reason" => reason}} ->
        ["  error: #{clip(reason, @output_bytes)}"]

      %Entry{type: :compaction} ->
        ["  the child compacted its context"]

      %Entry{type: :assistant, payload: payload} ->
        said(payload)

      _entry ->
        []
    end)
  end

  defp said(%{"content" => content}) when is_list(content) do
    case content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join(" ", & &1["text"]) do
      "" -> []
      text -> ["  the child wrote: #{clip(text, @output_bytes)}"]
    end
  end

  defp said(_payload), do: []

  defp clip(nil, _bytes), do: ""

  defp clip(text, bytes) when is_binary(text) do
    collapsed = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if byte_size(collapsed) > bytes,
      do: binary_slice(collapsed, 0, bytes) |> valid() |> Kernel.<>("…"),
      else: collapsed
  end

  defp clip(other, bytes), do: clip(inspect(other), bytes)

  defp valid(text), do: if(String.valid?(text), do: text, else: String.replace_invalid(text))

  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe_error(reason), do: inspect(reason)

  defp duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"

  defp duration(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1_000)
    if seconds == 0, do: "#{minutes}m", else: "#{minutes}m #{seconds}s"
  end
end
