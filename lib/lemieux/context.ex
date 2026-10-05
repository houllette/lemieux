defmodule Lemieux.Context do
  @moduledoc """
  How full a session's context window is, read off its transcript.

  Two different numbers live here and confusing them is the mistake this
  module exists to prevent:

    * **position** — where the last measured request stood in the window.
      The session projects the final prepared request from it before deciding
      to compact. A session that has compacted twice has a small position no
      matter how long it has been running.
    * **spend** — what the session has cost so far, cumulatively, including
      everything compaction removed. That was still paid for.

  Nothing here counts tokens itself. Counting them would mean a tokenizer,
  which is a dependency, provider-specific, and wrong for the provider it was
  not written for. What it reads is what the provider *reported* — the `usage`
  on the entries. Paid extension usage contributes to cumulative spend but
  never to the model's context-window position.

  ## Position is the last answer, not the sum of them

  Every request contains the whole conversation so far, so the requests
  overlap almost entirely. Adding them up measures how much has been sent,
  which is a much larger number than how much is in the window. The position
  is therefore the most recent request's input plus the answer it produced —
  and the tool results appended since, which nobody has measured yet.

  That last part is the known approximation: between a response and the next
  request, the position understates by however much the tools returned.
  Preflight also checks the prepared request's size, but cannot claim provider
  exactness without a host-supplied counter.

  A second, smaller gap: usage rides on the `:assistant` entry, and a turn that
  produced nothing at all — no text, no thinking, no tool call — persists no
  such entry, so what that request cost is not counted. It is a degenerate
  answer rather than a common one, and the position is measured again by the
  next request that produces something.

  ## Cache reads are context

  A cached prompt is cheap, not absent — it occupies the window exactly as it
  did before it was cached. Providers disagree about how to report it:
  Anthropic gives `cache_read_input_tokens` *outside* `input_tokens`, and
  OpenAI reports cached tokens as a subset of the prompt it already counted.
  `req_llm` normalises the difference into an `input_includes_cached` flag,
  and this module reads it. Getting it wrong is not subtle in either
  direction — double-counting a cached prompt overstates a long session by a
  third, and ignoring cache reads understates one by almost everything.

  ## Delegated tokens are spend, never position

  A child session has its own transcript, and its tokens will never be sent
  in the parent's next request — so they belong in what the run cost and
  nowhere near where the window stands. They arrive twice, deliberately: as
  `{:subagent, path, {:usage, usage}}` while a child runs, which
  `with_delegated_usage/2` accumulates so a fan-out's cost is visible before
  it finishes, and again as the `:subagent_result` entry the coordinator
  writes to the parent, which `position/2` reads. The second replaces the
  first rather than adding to it, because both are the same tokens counted
  the same way; that is also what makes a *cancelled* child's tokens land,
  since a cancellation still writes the result envelope.

  ## What the window is made of is apportioned, not counted

  `composition/2` answers "what is the window full of" — system prompt, tool
  schemas, conversation, the model's last answer, free space. The total is
  the provider's measurement, exactly as everywhere else here; the split
  across the three *sent* parts is each one's share of the bytes Lemieux
  actually handed the provider, read off the `:request` entry that recorded
  them.

  That is an apportionment and is labelled as one. Counting the parts
  directly would need a tokenizer, which this module opens by refusing, and
  the alternative to apportioning is saying nothing about a window that is
  mostly tool schemas — which is the question people actually have when it
  fills up.

  ## Compaction makes the position unmeasured, not small

  Right after a compaction the newest usage on the transcript describes the
  request that was too big — the one compaction just fixed. Reporting it would
  compact again immediately, and again after that, forever. So a `:compaction`
  entry newer than the newest usage means the position is *unmeasured*: zero,
  with `measured?: false` to say which kind of zero it is. The next response
  measures it truthfully.
  """

  alias Lemieux.Compaction
  alias Lemieux.Entry

  @typedoc """
  Where a session stands.

    * `tokens` — the position, in tokens.
    * `measured?` — whether `tokens` is a measurement or a placeholder. False
      for a session that has not asked anything yet, and for one that has just
      compacted.
    * `compacted?` — distinguishes an unknown position after compaction from a
      new session whose context has not been sent yet.
    * `window` — the model's context window, or `nil` when nothing knows it.
    * `fraction` — `tokens / window`, capped at 1.0, or `nil`.
    * `current` — the last measured request split into additive token classes.
      `input` is uncached input, so adding all four classes does not count a
      provider's cached-input subset twice.
    * `spent` — those same additive token classes, cumulatively, and the number
      of requests.
    * `delegated` — the same classes for work done by child sessions, kept
      apart from `spent` because it is the parent's bill and not the parent's
      window. No request count: a live child usage event is one child
      request, a persisted child result is one child, and a number that meant
      either would be wrong half the time.
  """
  @type t :: %__MODULE__{
          tokens: non_neg_integer(),
          measured?: boolean(),
          compacted?: boolean(),
          window: pos_integer() | nil,
          fraction: float() | nil,
          current: %{
            input: non_neg_integer(),
            cached: non_neg_integer(),
            cache_write: non_neg_integer(),
            output: non_neg_integer()
          },
          spent: %{
            input: non_neg_integer(),
            output: non_neg_integer(),
            cached: non_neg_integer(),
            cache_write: non_neg_integer(),
            requests: non_neg_integer()
          },
          delegated: %{
            input: non_neg_integer(),
            output: non_neg_integer(),
            cached: non_neg_integer(),
            cache_write: non_neg_integer()
          }
        }

  @typedoc """
  One band of `composition/2`: a labelled part of the context window.

  `tokens` is provider-measured for `:output` and `:free` and apportioned by
  byte share for the three parts that were sent. `fraction` is of the window
  when one is known, and of the measured position when none is.
  """
  @type segment :: %{
          key: :system | :tools | :conversation | :sent | :output | :free,
          label: String.t(),
          tokens: non_neg_integer(),
          fraction: float()
        }

  defstruct tokens: 0,
            measured?: false,
            compacted?: false,
            window: nil,
            fraction: nil,
            current: %{input: 0, output: 0, cached: 0, cache_write: 0},
            spent: %{input: 0, output: 0, cached: 0, cache_write: 0, requests: 0},
            delegated: %{input: 0, output: 0, cached: 0, cache_write: 0}

  @doc """
  Reads a transcript's position and spend.

  ## Options

    * `:window` — the model's context window. Without it there is no fraction
      and `full?/2` is always false: a threshold needs something to be a
      threshold of.
  """
  @spec position(entries :: [Entry.t()], opts :: keyword()) :: t()
  def position(entries, opts \\ []) do
    window = Keyword.get(opts, :window)
    {current, measured?, compacted?} = current(entries)
    tokens = token_total(current)

    %__MODULE__{
      tokens: tokens,
      measured?: measured?,
      compacted?: compacted?,
      window: window,
      fraction: fraction(tokens, window),
      current: current,
      spent: spent(entries),
      delegated: entries |> delegated_usages() |> summed()
    }
  end

  @doc """
  The usage maps of delegated work on a parent transcript.

  One selector, used both here and by `Lemieux.Session`'s usage summary,
  because the rule is subtle enough to drift if written twice: the per-child
  `:subagent_result` envelopes are the record, and the `:subagent_group_result`
  that follows them repeats the same usage — folding both counts a fan-out
  twice.
  """
  @spec delegated_usages(entries :: [Entry.t()]) :: [map()]
  def delegated_usages(entries) do
    Enum.flat_map(entries, fn
      %Entry{type: :subagent_result, payload: %{"usage" => usage}} when is_map(usage) -> [usage]
      _entry -> []
    end)
  end

  @doc """
  Applies provider-reported usage to the current context position.

  Streaming front ends use this between the provider's usage event and the
  durable transcript entry that will shortly produce the same position through
  `position/2`. Cumulative spend is deliberately left alone: only persisted
  entries count as completed requests, while this function describes the live
  request that is still settling.
  """
  @spec with_usage(context :: t(), usage :: map()) :: t()
  def with_usage(%__MODULE__{} = context, usage) when is_map(usage) do
    current = breakdown(usage)
    tokens = token_total(current)

    %{
      context
      | current: current,
        tokens: tokens,
        measured?: true,
        compacted?: false,
        fraction: fraction(tokens, context.window)
    }
  end

  @doc "Invalidates the measured window position and includes the summariser's usage."
  @spec after_compaction(context :: t(), usage :: map() | nil) :: t()
  def after_compaction(%__MODULE__{} = context, usage \\ nil) do
    spent =
      if is_map(usage) do
        request = breakdown(usage)

        context.spent
        |> add_breakdown(request)
        |> Map.put(:requests, context.spent.requests + 1)
      else
        context.spent
      end

    %{
      context
      | tokens: 0,
        measured?: false,
        compacted?: true,
        fraction: nil,
        current: %{input: 0, output: 0, cached: 0, cache_write: 0},
        spent: spent
    }
  end

  @doc """
  Adds one delegated child's usage to a live context.

  Streaming front ends use this between a child's usage event and the
  `:subagent_result` entry that will shortly produce the same total through
  `position/2` — so a fan-out's tokens climb while it runs rather than
  appearing all at once when it stops. The position is deliberately untouched:
  see the moduledoc.
  """
  @spec with_delegated_usage(context :: t(), usage :: map()) :: t()
  def with_delegated_usage(%__MODULE__{} = context, usage) when is_map(usage),
    do: %{context | delegated: add_breakdown(context.delegated, breakdown(usage))}

  @doc """
  Every token this session has been billed for, its children included.
  """
  @spec cumulative(context :: t()) :: non_neg_integer()
  def cumulative(%__MODULE__{spent: spent, delegated: delegated}),
    do: token_total(spent) + token_total(delegated)

  @doc """
  What a compaction moves the position from, and roughly to.

  The first number is a measurement: where the session stood when the
  summariser was asked. The second is not, and cannot be — a compaction makes
  the position *unmeasured* until the next response, for the reason this
  module's moduledoc gives, and the alternative to estimating is telling
  somebody that summarising a conversation took the window to zero.

  So it is apportioned, exactly as `composition/2` apportions the bands and
  with the same caveat: the system prompt and the tool schemas survive a
  compaction untouched, and what shrinks is the conversation, by the share of
  its bytes that `dropped` carried away — less the summary that replaces them.
  Callers should render it as an estimate. The next response measures it.

  `nil` when the position was never measured, or when no request on the
  transcript records what its bytes were spent on: both are cases where the
  only honest answer is the entry count the caller already has.
  """
  @spec compacted(
          context :: t(),
          entries :: [Entry.t()],
          dropped :: [Entry.t()],
          summary :: String.t() | nil
        ) :: %{before: non_neg_integer(), after: non_neg_integer()} | nil
  def compacted(context, entries, dropped, summary \\ nil)

  def compacted(%__MODULE__{measured?: false}, _entries, _dropped, _summary), do: nil

  def compacted(%__MODULE__{tokens: tokens} = context, entries, dropped, summary) do
    current = compatible_current(context)
    sent = current.input + current.cached + current.cache_write

    case apportioned(sent, entries) do
      nil ->
        nil

      %{bytes: 0} ->
        nil

      bands ->
        kept = max(bands.bytes - Enum.reduce(dropped, 0, &(entry_bytes(&1.payload) + &2)), 0)
        remaining = kept + payload_bytes(summary)
        conversation = div(bands.conversation * remaining, bands.bytes)

        # The model's last answer is in the tail a compaction keeps — the cut
        # is at a turn boundary in the older seventy per cent — so it is still
        # in the window afterwards and still counted here.
        after_tokens = bands.system + bands.tools + conversation + current.output

        %{before: tokens, after: min(after_tokens, tokens)}
    end
  end

  @doc """
  Every token a session's children have been billed for.
  """
  @spec delegated_tokens(context :: t()) :: non_neg_integer()
  def delegated_tokens(%__MODULE__{delegated: delegated}), do: token_total(delegated)

  @doc """
  What the context window is made of, as ordered bands that tile it exactly.

  `entries` is the transcript the position was read from: the newest
  `:request` entry records the system text and the tool schemas that were
  sent and names the conversation entries that went with them, and their
  byte shares are how the measured input is divided. A transcript with no
  such entry — an older one, or a session whose first request has not landed
  — collapses the three into one `:sent` band rather than guessing at a split.

  Empty for an unmeasured position: there is nothing to draw a window out of,
  and drawing an empty one would claim the window is free when nobody has
  looked.
  """
  @spec composition(context :: t(), entries :: [Entry.t()]) :: [segment()]
  def composition(context, entries \\ [])
  def composition(%__MODULE__{measured?: false}, _entries), do: []

  def composition(%__MODULE__{} = context, entries) do
    current = compatible_current(context)
    sent = current.input + current.cached + current.cache_write
    whole = whole(context)

    (sent_segments(sent, entries) ++
       [
         {:output, "model output", current.output},
         {:free, "free", free(context)}
       ])
    |> Enum.reject(fn {_key, _label, tokens} -> tokens <= 0 end)
    |> Enum.map(fn {key, label, tokens} ->
      %{key: key, label: label, tokens: tokens, fraction: tokens / whole}
    end)
  end

  # The denominator every band is a fraction of. The window when one is
  # known, so the bar shows how much room is left; the position otherwise, so
  # a model nobody has published limits for still gets a readable split
  # instead of a bar of nothing.
  defp whole(%__MODULE__{window: window, tokens: tokens}) when is_integer(window) and window > 0,
    do: max(window, tokens)

  defp whole(%__MODULE__{tokens: tokens}), do: max(tokens, 1)

  defp free(%__MODULE__{window: window, tokens: tokens}) when is_integer(window),
    do: max(window - tokens, 0)

  defp free(_context), do: 0

  defp sent_segments(sent, entries) do
    case apportioned(sent, entries) do
      nil ->
        [{:sent, "sent", sent}]

      bands ->
        [
          {:system, "system prompt", bands.system},
          {:tools, "tools & MCP", bands.tools},
          {:conversation, "conversation", bands.conversation}
        ]
    end
  end

  # The measured input split across the three things that were sent, by their share
  # of the bytes. Each band takes its floor and the last takes what is left, so the
  # bands add up to the measured total exactly. `nil` rather than zeroes when there
  # is no request to read shares off, which is a different thing from a request
  # that sent nothing.
  defp apportioned(sent, entries) do
    case request_bytes(entries) do
      nil ->
        nil

      shares ->
        system = div(sent * shares.system, shares.total)
        tools = div(sent * shares.tools, shares.total)

        %{
          system: system,
          tools: tools,
          conversation: max(sent - system - tools, 0),
          bytes: shares.conversation
        }
    end
  end

  # The newest `:request` entry is the one the measured usage belongs to.
  # Walked from the newest so a long transcript costs one step, and `nil`
  # rather than zeroes when there is none: no request means no shares, which
  # is a different thing from a request that sent nothing.
  defp request_bytes(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :request))
    |> case do
      %Entry{payload: %{} = payload} -> shares(payload, entries)
      _otherwise -> nil
    end
  end

  defp shares(payload, entries) do
    system = system_bytes(payload)
    tools = tools_bytes(payload)
    conversation = conversation_bytes(payload, entries)
    total = system + tools + conversation

    if total > 0,
      do: %{system: system, tools: tools, conversation: conversation, total: total},
      else: nil
  end

  # A request recorded at `:digests` evidence keeps sizes rather than the
  # prompt and schemas themselves; the split is drawn from those.
  defp system_bytes(%{"system" => system}) when is_binary(system), do: byte_size(system)
  defp system_bytes(%{"system_bytes" => bytes}) when is_integer(bytes), do: bytes
  defp system_bytes(_payload), do: 0

  defp tools_bytes(%{"evidence" => "digests", "catalog" => %{"bytes" => bytes}})
       when is_integer(bytes),
       do: bytes

  defp tools_bytes(payload), do: payload |> Map.get("tools") |> payload_bytes()

  # `entry_ids` names exactly what the request carried, so the conversation's
  # size is those entries and not the whole transcript — which still holds
  # everything compaction dropped.
  defp conversation_bytes(payload, entries) do
    case Map.get(payload, "entry_ids") do
      ids when is_list(ids) and ids != [] ->
        wanted = MapSet.new(ids)

        entries
        |> Enum.filter(&MapSet.member?(wanted, &1.id))
        |> Enum.reduce(0, &(entry_bytes(&1.payload) + &2))

      _otherwise ->
        0
    end
  end

  # An attachment is weighed the way compaction weighs it, not by its base64:
  # a screenshot counted byte for byte would show as most of the conversation
  # on the display meant to say where the context went.
  defp entry_bytes(%{"attachments" => [_ | _] = attachments} = payload),
    do:
      payload_bytes(Map.delete(payload, "attachments")) +
        length(attachments) * Compaction.attachment_weight_bytes()

  defp entry_bytes(payload), do: payload_bytes(payload)

  # Measured rather than encoded: `JSON.encode!/1` on a long transcript is
  # real work for a display, and a share only needs the sizes to be
  # proportional to each other. A number stands for its JSON width.
  defp payload_bytes(value) when is_binary(value), do: byte_size(value)

  defp payload_bytes(value) when is_map(value),
    do:
      Enum.reduce(value, 0, fn {key, inner}, total ->
        total + payload_bytes(key) + payload_bytes(inner)
      end)

  defp payload_bytes(value) when is_list(value),
    do: Enum.reduce(value, 0, &(payload_bytes(&1) + &2))

  defp payload_bytes(value) when is_atom(value), do: value |> Atom.to_string() |> byte_size()

  defp payload_bytes(value) when is_integer(value),
    do: value |> Integer.to_string() |> byte_size()

  defp payload_bytes(value) when is_float(value), do: 8
  defp payload_bytes(_value), do: 0

  # Walked newest-first and stopped at the first thing that answers the
  # question — either a usage to read, or the compaction that invalidated
  # every usage before it.
  defp current(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(
      &(&1.type == :compaction or
          (&1.type not in [:guidance, :extension_state] and is_map(&1.usage)))
    )
    |> case do
      %Entry{type: :compaction} -> {empty_breakdown(), false, true}
      %Entry{usage: usage} when is_map(usage) -> {breakdown(usage), true, false}
      _otherwise -> {empty_breakdown(), false, false}
    end
  end

  defp breakdown(usage) do
    input = number(usage, "input_tokens")
    cached = number(usage, "cache_read_tokens", "cached_tokens")
    cache_write = number(usage, "cache_write_tokens", "cache_creation_tokens")
    output = number(usage, "output_tokens")

    input =
      if includes_cached?(usage),
        do: max(input - cached - cache_write, 0),
        else: input

    %{input: input, cached: cached, cache_write: cache_write, output: output}
  end

  # Builds before Usage preserved JSON booleans wrote this flag as "true" or
  # "false". Accept the historical form so resuming such a transcript does not
  # silently double-count an OpenAI cache read.
  defp includes_cached?(usage),
    do: Map.get(usage, "input_includes_cached") in [true, "true"]

  # Read with defaults, for the reason `number/2` below swallows a surprising
  # value: these maps come out of hosts and out of transcripts written by older
  # builds, and one absent key is not worth taking a status line down for.
  defp token_total(breakdown) when is_map(breakdown) do
    Map.get(breakdown, :input, 0) + Map.get(breakdown, :cached, 0) +
      Map.get(breakdown, :cache_write, 0) + Map.get(breakdown, :output, 0)
  end

  defp add_breakdown(total, request),
    do: %{
      input: Map.get(total, :input, 0) + request.input,
      output: Map.get(total, :output, 0) + request.output,
      cached: Map.get(total, :cached, 0) + request.cached,
      cache_write: Map.get(total, :cache_write, 0) + request.cache_write
    }

  defp summed(usages),
    do: Enum.reduce(usages, empty_breakdown(), &add_breakdown(&2, breakdown(&1)))

  defp empty_breakdown, do: %{input: 0, cached: 0, cache_write: 0, output: 0}

  defp spent(entries) do
    entries
    |> Enum.filter(&is_map(&1.usage))
    |> Enum.reduce(Map.put(empty_breakdown(), :requests, 0), fn entry, spent ->
      request = breakdown(entry.usage)

      %{
        input: spent.input + request.input,
        output: spent.output + request.output,
        cached: spent.cached + request.cached,
        cache_write: spent.cache_write + request.cache_write,
        requests: spent.requests + 1
      }
    end)
  end

  # A usage map is whatever a provider sent, through a JSON round trip, and
  # possibly from a build of lemieux that recorded different fields. A missing
  # or unexpected value is zero rather than a crash: an accounting number is
  # not worth taking a session down for.
  defp number(usage, key) do
    case Map.get(usage, key) do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      _otherwise -> 0
    end
  end

  defp number(usage, preferred, fallback) do
    if is_number(Map.get(usage, preferred)),
      do: number(usage, preferred),
      else: number(usage, fallback)
  end

  defp fraction(_tokens, nil), do: nil
  defp fraction(_tokens, window) when window <= 0, do: nil
  defp fraction(tokens, window), do: min(tokens / window, 1.0)

  @doc """
  Whether the window is full enough to compact.

  Always false when the window is unknown. A session whose model `req_llm` has
  never heard of should keep running rather than compact on a guess — the
  worst case is the provider's own "too many tokens" error, which is a clear
  message, while compacting on a wrong window silently throws away a
  conversation that had room.
  """
  @spec full?(context :: t(), threshold :: float()) :: boolean()
  def full?(%__MODULE__{fraction: nil}, _threshold), do: false
  def full?(%__MODULE__{fraction: fraction}, threshold), do: fraction >= threshold

  @doc """
  A short human-readable position, for a status line.

      iex> Lemieux.Context.describe(%Lemieux.Context{tokens: 0, measured?: false})
      "context unmeasured"
  """
  @spec describe(context :: t()) :: String.t()
  def describe(%__MODULE__{measured?: false}), do: "context unmeasured"

  def describe(%__MODULE__{fraction: nil} = context),
    do: "#{thousands(context.tokens)} tokens"

  def describe(%__MODULE__{} = context) do
    "#{thousands(context.tokens)}/#{thousands(context.window)} tokens " <>
      "(#{percentage(context.fraction)})"
  end

  @doc "A provider-reported breakdown for the interactive `/context` command."
  @spec details(context :: t()) :: String.t()
  def details(%__MODULE__{} = context) do
    current = current_lines(context)
    spent = context.spent

    (current ++
       [
         "",
         "Session total",
         "  Requests         #{Map.get(spent, :requests, 0)}",
         token_line("Uncached input", Map.get(spent, :input, 0)),
         token_line("Cache read", Map.get(spent, :cached, 0)),
         token_line("Cache write", Map.get(spent, :cache_write, 0)),
         token_line("Model output", Map.get(spent, :output, 0))
       ] ++ delegated_lines(context))
    |> Enum.join("\n")
  end

  # Named rather than folded into the total above: delegated tokens were
  # billed to this run and are not in this session's window, and a reader who
  # cannot tell which is which cannot use either number.
  defp delegated_lines(%__MODULE__{delegated: delegated}) do
    if token_total(delegated) > 0 do
      [
        "",
        "Delegated to child sessions",
        token_line("Uncached input", delegated.input),
        token_line("Cache read", delegated.cached),
        token_line("Cache write", delegated.cache_write),
        token_line("Model output", delegated.output)
      ]
    else
      []
    end
  end

  defp current_lines(%__MODULE__{measured?: false}) do
    [
      "Context window",
      "  Unmeasured — new session or just compacted"
    ]
  end

  defp current_lines(%__MODULE__{} = context) do
    current = compatible_current(context)

    [
      "Context window (last measured request)",
      "  Used             #{describe(context)}",
      token_line("Uncached input", current.input),
      token_line("Cache read", current.cached),
      token_line("Cache write", current.cache_write),
      token_line("Model output", current.output)
    ] ++ available_line(context)
  end

  # A caller may have constructed the public struct before `current` existed.
  # Preserve a truthful total in that case rather than displaying four zeroes
  # under a non-zero Used line; the provider-specific split is simply unknown.
  defp compatible_current(%__MODULE__{tokens: tokens, current: current}) do
    if token_total(current) == tokens,
      do: current,
      else: %{input: tokens, cached: 0, cache_write: 0, output: 0}
  end

  defp available_line(%__MODULE__{window: window, tokens: tokens}) when is_integer(window),
    do: [token_line("Available", max(window - tokens, 0))]

  defp available_line(_context), do: []

  defp token_line(label, tokens),
    do: "  #{String.pad_trailing(label, 17)}#{thousands(tokens)} tokens"

  @doc """
  A token count at a glance: `9.0k`, `1.2m`, `512`.

  Public because a legend and a status line need the same abbreviation this
  module's own reports use, and a second copy of it drifts by one decimal
  place and then reads like two different measurements.
  """
  @spec abbreviate(tokens :: non_neg_integer()) :: String.t()
  def abbreviate(tokens) when is_integer(tokens) and tokens >= 0, do: thousands(tokens)

  defp thousands(tokens) when tokens < 1_000, do: Integer.to_string(tokens)
  defp thousands(tokens) when tokens < 1_000_000, do: "#{fixed(tokens / 1_000)}k"
  defp thousands(tokens), do: "#{fixed(tokens / 1_000_000)}m"

  defp fixed(amount), do: :erlang.float_to_binary(amount, decimals: 1)

  defp percentage(fraction) when fraction <= 0.0, do: "0%"
  defp percentage(fraction) when fraction < 0.01, do: "<1%"
  defp percentage(fraction), do: "#{round(fraction * 100)}%"
end
