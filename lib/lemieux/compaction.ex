defmodule Lemieux.Compaction do
  @moduledoc """
  Making a long conversation fit, without losing what happened.

  When a session fills its context window the elder part of the conversation
  is summarised and stops being sent. Two things about how that is done here
  are load-bearing.

  ## It is an entry, not a rewrite

  Compaction **appends**. It writes a `:compaction` entry saying what was
  summarised and what the summary is, and it deletes nothing. Everything
  `Lemieux.Entry` promises — resume, fork, replay — is a read over an
  append-only list, and a compaction that edited the list would quietly break
  all three: a transcript replayed after compaction would show a conversation
  that never happened, and a fork taken from before the cut would be
  unforkable.

  So there are two different views of one transcript, and both are honest:

    * **what happened** — every entry, which is what `Lemieux.Store.read/2`
      returns and what a log or a replay renders;
    * **what is sent** — `applied/1`, the tail after the newest cut, with
      `summary/1` standing in for everything before it.

  ## The cut lands on a message boundary, or it does not happen

  A conversation split between a model's tool call and that call's result is
  one every provider rejects. A cut therefore begins at a `:user` entry when
  there is one to begin at, and otherwise at an `:assistant` entry, which
  retains that message and the tool results following it. The second is what
  lets the commonest long session compact at all: one prompt, then a hundred
  rounds of tool calls under it, has no second `:user` entry anywhere. The
  earlier user instruction is carried by the summary. A result is never
  retained without the assistant message that called its tool.

  A tail that begins at an assistant message would make the request begin
  with one, which some providers refuse. `applied/2` puts a short user
  message in front of it — a projection, never written to the transcript —
  saying that what came before is summarised in the system prompt.

  The requested cut point is therefore a suggestion: the real one is the first
  turn boundary at or after it, which keeps *less* than asked rather than more.
  Erring the other way would mean occasionally sending a conversation the
  provider refuses, and the failure would arrive as an opaque 400 in the middle
  of a long session.

  A transcript with no safe boundary is left alone. That session may hit the
  provider's token limit, but does not send an orphaned tool result.

  ## How much is kept is an estimate

  The historical `:keep` option uses entry count. `:keep_recent_tokens` uses
  encoded entry bytes divided by four. Neither is a provider tokenizer; the
  latter at least distinguishes a large file from a short answer. The session
  checks the prepared request separately before dispatch.

  ## Structured sections, when a host asks for them

  A summary is free prose by default, and prose is where a long run loses
  its obligations: an acceptance criterion the person stated an hour ago,
  a follow-up the model discovered and meant to come back to, a change it
  made and never tested. ADR-0001 names that as the plausible failure of
  summarising and names the lighter remedy — require `open work`,
  `dependencies`, `decisions` and `verification debt` sections in the
  summary — as something to measure rather than assume. So it is an
  option, `:summary_sections`, off by default: `instructions/2` asks the
  summariser for the four sections when it is on, `sections/1` reads them
  back out of the answer, and `Lemieux.Session` records what it read in the
  `:compaction` entry and the `{:compacted, …}` event. A summary that comes
  back without them is still a summary — a cut with nothing standing in
  for it is worse than a cut with prose — and `sections/1` says so with
  `nil`, which is how a host running the experiment tells the two apart.

  ## A seam, and this module is its default

  This module is two things at once, deliberately. It declares the behaviour
  a host implements to compact its own way, and it *is* the implementation
  `Lemieux.Session` uses unless told otherwise — so the contract cannot drift
  from the thing it describes, and the shipped rules are a worked example of
  the behaviour rather than a paragraph about one. `Lemieux.Store` and
  `Lemieux.TUI.Status` are built the same way.

  A host passes `compaction: MyApp.Compaction` or
  `compaction: {MyApp.Compaction, state}` to `Lemieux.start_session/1`. The
  callbacks take that state first, as a store's do, and the pure functions
  below are what the default callbacks call with the state ignored. What the
  seam hands over is *how*: where to cut, what a request carries after a cut,
  what the summariser is asked and how its answer is put in front of later
  requests. What it keeps is *when*: prepared-request window and price
  checks, a short-lived host advisory, explicit `compact/2`, and a provider's
  context-limit refusal all enter through the session. They cut only between
  turns, because only the session knows it is between turns. A replacement
  that cut inside one would produce a request the provider rejects.

  The option is host behaviour, like `:hooks` — neither recorded in the
  transcript nor restored from it — while what it writes is not: the
  `:compaction` entry and the `{:compacted, …}` event keep their shape
  whichever module produced the summary, so a replay and a resume read
  both the same way.
  """

  @behaviour __MODULE__

  alias Lemieux.Entry

  # Below this there is nothing worth the round trip: summarising four entries
  # costs a request to save a few hundred tokens.
  @minimum 8

  # The share of the window a retained tail may take when the caller gave a
  # window and no target. With the trigger at 0.8 of the window, a cut to 0.3
  # leaves half the window for work before the next one.
  @window_share 0.3

  # The four sections, in the order the summariser is asked for them and the
  # heading each one is asked for under.
  @sections [
    {:open_work, "Open work"},
    {:dependencies, "Dependencies"},
    {:decisions, "Decisions"},
    {:verification_debt, "Verification debt"}
  ]

  # A heading is `## Open work`, or the same in bold, upper case, or with a
  # colon: models vary in how faithfully they reproduce a heading, and a
  # section lost to a stray colon is the failure this is meant to prevent.
  @heading ~r/^\s*(?:\#{1,6}\s*|\*\*)?([A-Za-z][A-Za-z ]+?)\s*:?\s*(?:\*\*)?\s*:?\s*$/
  @bullet ~r/^\s*(?:[-*+•]|\d{1,3}[.)])\s+/u

  # The entry types that become messages at the provider seam. Everything else
  # on a transcript — the request snapshots, the approvals, the session
  # configuration, the compactions themselves — is a durable fact about the run
  # rather than a turn in the conversation.
  @conversational ~w(user assistant tool_result system)a

  # What stands in front of a tail that begins mid-turn. It says where the
  # missing beginning went rather than inventing a request the person never made.
  @continuation "[The earlier part of this conversation is summarised in the system " <>
                  "prompt. Continue from where it left off.]"

  # What closes a summarising request. Without it the request ended on whatever
  # the elder conversation ended on, often an assistant message, which
  # Anthropic reads as a reply to continue rather than a conversation to
  # summarise.
  @summarise "Write the summary of the conversation above now, as your instructions describe."

  # Stubbing defaults, used when a caller asks for stubbing without saying how:
  # the newest forty results stay whole, older ones are stubbed twenty at a time
  # so the cached prefix changes once per twenty calls, and only outputs worth
  # the words it takes to say they are gone.
  @stub_keep 40
  @stub_batch 20
  @stub_min_bytes 4_096

  # What an image or document is weighed at when estimating: about 1,600
  # tokens, the order of what a provider charges for one image, at the four
  # bytes a token the estimate assumes. Its base64 read as prose would be a
  # screenshot weighed as a novel, and a plan sized on that keeps nothing.
  @attachment_weight_bytes 6_400

  @doc """
  The bytes one image or document attachment is weighed at when estimating.

  Shared so every estimate agrees: `Lemieux.Context`'s `/context` shares use
  it too, and a display that counted base64 would show a screenshot as most
  of the conversation.
  """
  @spec attachment_weight_bytes() :: pos_integer()
  def attachment_weight_bytes, do: @attachment_weight_bytes

  @typedoc "A proposed cut: what to summarise, and what to keep."
  @type plan :: %{elder: [Entry.t()], tail: [Entry.t()]}

  @typedoc "The four structured sections of a summary, each a list of items."
  @type sections :: %{
          open_work: [String.t()],
          dependencies: [String.t()],
          decisions: [String.t()],
          verification_debt: [String.t()]
        }

  @typedoc """
  How a session compacts: a module implementing this behaviour, or one paired
  with its own state.
  """
  @type t :: module() | {module(), state :: term()}

  @doc """
  Chooses where to cut the sendable conversation, or `:nothing_to_do`.

  `entries` is what a request would carry now — `c:applied/3` has already been
  taken — and `opts` carries `:keep` when the host set it. `:nothing_to_do`
  makes a threshold compaction fall through to the turn and an explicit
  `Lemieux.Session.compact/2` answer `{:error, :nothing_to_do}`. `plan.elder`
  is what the summariser is sent; its first and last ids are recorded in the
  `:compaction` entry, so it must be a contiguous slice of `entries`.
  """
  @callback plan(state :: term(), entries :: [Entry.t()], opts :: keyword()) ::
              {:ok, plan()} | :nothing_to_do

  @doc """
  The entries a request should carry, given everything on the transcript.

  Called with `keep_attachments:` when building a request, and without options
  when deciding what a compaction would cut. `plan/3` is handed the result.
  """
  @callback applied(state :: term(), entries :: [Entry.t()], opts :: keyword()) :: [Entry.t()]

  @doc "Whether anything is still being sent; what `Lemieux.Session.clear/1` asks first."
  @callback conversation?(state :: term(), entries :: [Entry.t()]) :: boolean()

  @doc "What the newest compaction summarised, or `nil` if there has not been one."
  @callback summary(state :: term(), entries :: [Entry.t()]) :: String.t() | nil

  @doc "The structured sections read back out of a summary, or `nil` when it has none."
  @callback sections(state :: term(), summary :: String.t() | nil) :: sections() | nil

  @doc """
  The system prompt for the summarising request.

  `previous` is the summary an earlier compaction left, if any, and `opts`
  carries `sections:` from the session's `:summary_sections`. The request
  this goes into has no tools and the plan's elder entries as its
  conversation.
  """
  @callback instructions(state :: term(), previous :: String.t() | nil, opts :: keyword()) ::
              String.t()

  @doc """
  How a summary is put in front of an ordinary request, given the session's
  system prompt. Called for every request, with `summary` `nil` until there
  has been a compaction.
  """
  @callback with_summary(
              state :: term(),
              system :: String.t() | nil,
              summary :: String.t() | nil
            ) :: String.t() | nil

  @doc """
  Chooses where to cut, or `:nothing_to_do`.

  ## Options

    * `:keep` — roughly what fraction of the conversation to keep, by entry
      count. Used when no token target applies, defaulting to `0.3`.
    * `:keep_recent_tokens` — estimated maximum tokens of conversation to
      retain.
    * `:window` — the window, in tokens, the session is compacting against.
      Information rather than an instruction: with neither `:keep` nor
      `:keep_recent_tokens` given, the target becomes
      #{round(@window_share * 100)}% of it, and never more than half of the
      conversation as it stands, so a compaction always cuts something.

  Either way a safe assistant boundary is used within a long user turn when
  no user boundary lies at or after the suggested cut.
  """
  @spec plan(entries :: [Entry.t()], opts :: keyword()) :: {:ok, plan()} | :nothing_to_do
  def plan(entries, opts \\ [])

  def plan(entries, _opts) when length(entries) < @minimum, do: :nothing_to_do

  def plan(entries, opts) do
    index =
      case keep_target(entries, opts) do
        target when is_integer(target) and target > 0 ->
          token_boundary(entries, target)

        _none ->
          keep = Keyword.get(opts, :keep, 0.3)
          suggested = length(entries) - max(round(length(entries) * keep), 1)
          boundary(entries, suggested, :user) || boundary(entries, suggested, :assistant)
      end

    case index do
      nil -> :nothing_to_do
      0 -> :nothing_to_do
      index -> {:ok, %{elder: Enum.take(entries, index), tail: Enum.drop(entries, index)}}
    end
  end

  @impl true
  def plan(_state, entries, opts), do: plan(entries, opts)

  # An explicit target wins; an explicit fraction asks for the count rule; with
  # neither, a window makes a token target. Half the conversation is the ceiling
  # because a target larger than what is there keeps everything, and a
  # compaction that summarised nothing would be paid for on every turn.
  defp keep_target(entries, opts) do
    case {Keyword.get(opts, :keep_recent_tokens), Keyword.get(opts, :keep),
          Keyword.get(opts, :window)} do
      {target, _keep, _window} when is_integer(target) and target > 0 ->
        target

      {_target, nil, window} when is_integer(window) and window > 0 ->
        max(min(round(window * @window_share), div(estimated_tokens(entries), 2)), 1)

      _count ->
        nil
    end
  end

  @doc """
  The estimated size of `entries`, in tokens.

  Encoded bytes divided by four, the estimate every token target here is
  measured in, counting only the entries a provider turns into messages: a
  request snapshot or a session record weighs nothing. Not a provider
  tokenizer.
  """
  @spec estimated_tokens(entries :: [Entry.t()]) :: non_neg_integer()
  def estimated_tokens(entries), do: entries |> Enum.map(&entry_tokens/1) |> Enum.sum()

  # The first entry of `type` at or after the suggested index, never the first
  # entry of all. Searching forward rather than backward is what makes the cut
  # keep less than asked: a boundary behind the suggestion would put a whole
  # turn back into the tail that the caller wanted summarised.
  defp boundary(entries, suggested, type) do
    entries
    |> Enum.with_index()
    |> Enum.find_value(fn {entry, index} ->
      if index > 0 and index >= suggested and entry.type == type, do: index
    end)
  end

  defp token_boundary(entries, target) do
    weights = Enum.map(entries, &entry_tokens/1)
    total = Enum.sum(weights)

    {candidate, _remaining} =
      entries
      |> Enum.zip(weights)
      |> Enum.with_index()
      |> Enum.reduce({nil, total}, fn {{entry, weight}, index}, {candidate, remaining} ->
        candidate =
          if candidate == nil and index > 0 and remaining <= target and entry.type == :user,
            do: index,
            else: candidate

        {candidate, remaining - weight}
      end)

    candidate || assistant_boundary(entries, weights, target)
  end

  defp assistant_boundary(entries, weights, target) do
    total = Enum.sum(weights)

    entries
    |> Enum.zip(weights)
    |> Enum.with_index()
    |> Enum.reduce_while({:remaining, total}, fn {{entry, weight}, index},
                                                 {:remaining, remaining} ->
      if index > 0 and remaining <= target and entry.type == :assistant do
        {:halt, {:boundary, index}}
      else
        {:cont, {:remaining, remaining - weight}}
      end
    end)
    |> case do
      {:boundary, index} -> index
      _none -> nil
    end
  end

  # Only what a provider sends has weight: a request snapshot holds the whole
  # system prompt and tool catalog, and counted it shrank the retained tail.
  defp entry_tokens(%Entry{type: type}) when type not in @conversational, do: 0

  defp entry_tokens(entry) do
    entry.payload
    |> weighed()
    |> JSON.encode!()
    |> byte_size()
    |> then(&max(div(&1 + 3, 4), 1))
  end

  # A prompt's `@` attachments and a tool result's images share the key and the
  # shape (`Lemieux.Tool.Attachment`), so one rule weighs both.
  defp weighed(%{"attachments" => [_ | _] = attachments} = payload),
    do: Map.put(payload, "attachments", Enum.map(attachments, &weighed_attachment/1))

  defp weighed(payload), do: payload

  defp weighed_attachment(%{"data" => data} = attachment) when is_binary(data),
    do: Map.put(attachment, "data", String.duplicate("*", @attachment_weight_bytes))

  defp weighed_attachment(attachment), do: attachment

  defp shed_media(entries, :all), do: entries

  defp shed_media(entries, keep) when is_integer(keep) and keep >= 0 do
    carrying = Enum.filter(entries, &media?/1)
    batch = max(keep, 1)
    count = div(max(length(carrying) - keep, 0), batch) * batch
    shed = carrying |> Enum.take(count) |> MapSet.new(& &1.id)

    if MapSet.size(shed) == 0,
      do: entries,
      else: Enum.map(entries, &without_media(&1, shed))
  end

  defp media?(%Entry{type: :tool_result, payload: %{"attachments" => [_ | _]}}), do: true
  defp media?(%Entry{}), do: false

  defp without_media(%Entry{payload: payload} = entry, shed) do
    if MapSet.member?(shed, entry.id) do
      count = length(payload["attachments"])
      what = if count == 1, do: "the image or document", else: "the #{count} images or documents"

      note =
        "[#{what} this earlier call returned #{if count == 1, do: "is", else: "are"} no longer " <>
          "attached; call it again if you still need to see #{if count == 1, do: "it", else: "them"}]"

      payload =
        payload
        |> Map.delete("attachments")
        |> Map.update("output", note, &(&1 <> "\n" <> note))

      %{entry | payload: payload}
    else
      entry
    end
  end

  @doc """
  The entries a request should carry, given everything on the transcript.

  Everything up to and including the newest compaction's cut point is dropped,
  and so is the compaction entry itself — it is not a message. What it said
  travels as `summary/1` instead.

  ## Shedding attachments, which is a second kind of too-large

  A file attached to a prompt by an `@`-reference lives in that `:user` entry,
  and a `:user` entry is re-sent on every request for the rest of the
  conversation. Compaction eventually eats it, but only once the window is
  nearly full — until then a single attached file is paid for again on every
  turn of a long session, at full price, for a question that was answered
  twenty turns ago.

  `:keep_attachments` bounds that: the newest N prompts that carried
  attachments keep them, and older ones carry a note naming the file instead.
  The note matters. An attachment that simply vanished would leave a model
  answering from a memory of a file it can no longer check, which is the
  failure this whole library keeps arguing against; a model told the file is
  no longer included reads it again with the `read` tool.

  It is a projection, not a rewrite. The entries on disk still hold every
  attachment, so `Lemieux.Store.read/2`, a fork and a replay all still see
  what was actually attached — the same distinction between *what happened*
  and *what is sent* that compaction itself is built on.

  ## Old tool output, which is the third

  A long run's request is mostly tool output — whole files, whole build logs
  — and the model needs little of it after a few dozen more calls. Carrying
  every byte to the compaction threshold means paying full price for it on
  every request, and a model that reasons over text it no longer needs.
  `:stub_tool_results` replaces the output of old, large results with a
  line saying what was there and that running the call again recovers it.

  The stubbed set grows in batches, not one result at a time. A prompt cache
  keeps a prefix only while it is unchanged, and a sliding window would
  change the prefix on every request; a batch changes it once per batch.

  ## Options

    * `:keep_attachments` — how many attachment-carrying prompts keep their
      attachments, newest first. `:all` to shed nothing, which is the default
      so that a caller reading a transcript for any other purpose gets the
      transcript.
    * `:stub_tool_results` — `nil` (the default) to send every tool result
      whole, or a keyword list: `:keep`, the newest results always sent
      whole (#{@stub_keep}); `:batch`, how many older ones are stubbed at a
      time (#{@stub_batch}); `:min_bytes`, the output size below which a
      result is left alone (#{@stub_min_bytes}).
    * `:keep_media` — how many tool results that carry images or documents
      (`Lemieux.Tool.Attachment`) keep them, newest first; `:all`, the
      default, sends every one. Older ones lose them in batches of the same
      size, so a cached prefix changes once per that many new images rather
      than on every one, and their output says what is no longer attached.
      A session sets it (see `Lemieux.Session`'s `:keep_media`), because a
      browser run takes a screenshot a step and resending every one of them
      on every request costs more than the rest of the conversation.

  Whatever the options, a partial assistant answer — kept on the transcript
  when a failed request was retried, marked `"partial" => true` — is never
  sent, and a tail that would begin with an assistant message is given the
  short user message the module documentation describes.
  """
  @spec applied(entries :: [Entry.t()], opts :: keyword()) :: [Entry.t()]
  def applied(entries, opts \\ []) do
    entries
    |> after_compaction()
    |> Enum.reject(&partial?/1)
    |> shed(Keyword.get(opts, :keep_attachments, :all))
    |> shed_media(Keyword.get(opts, :keep_media, :all))
    |> stub(Keyword.get(opts, :stub_tool_results))
    |> continued()
  end

  @doc """
  The conversation a summarising request carries: `elder`, closed by a short
  user message asking for the summary.

  A projection like `applied/2`'s lead message: never written to the
  transcript, and built from the last elder entry so the same elder always
  makes the same request.
  """
  @spec summarising(elder :: [Entry.t()]) :: [Entry.t()]
  def summarising([]), do: []

  def summarising(elder) do
    last = List.last(elder)

    elder ++
      [
        %Entry{
          id: last.id <> "-summarise",
          parent_id: last.id,
          seq: last.seq,
          type: :user,
          payload: %{"text" => @summarise},
          meta: %{"synthetic" => true},
          at: last.at
        }
      ]
  end

  @doc """
  Whether `entry` is a partial answer kept only as a record.

  A request that failed after the model had started answering is retried from
  the transcript; what it had said so far is kept for a reader and never sent,
  because the retried request answers the same question again.
  """
  @spec partial?(entry :: Entry.t()) :: boolean()
  def partial?(%Entry{type: :assistant, payload: %{"partial" => true}}), do: true
  def partial?(%Entry{}), do: false

  defp stub(entries, nil), do: entries
  defp stub(entries, false), do: entries

  defp stub(entries, opts) when is_list(opts) do
    keep = Keyword.get(opts, :keep, @stub_keep)
    batch = max(Keyword.get(opts, :batch, @stub_batch), 1)
    min_bytes = Keyword.get(opts, :min_bytes, @stub_min_bytes)
    results = Enum.filter(entries, &(&1.type == :tool_result))
    count = div(max(length(results) - keep, 0), batch) * batch

    stubbed =
      results
      |> Enum.take(count)
      |> Enum.filter(&large_output?(&1, min_bytes))
      |> MapSet.new(& &1.id)

    if MapSet.size(stubbed) == 0,
      do: entries,
      else: Enum.map(entries, &stub_entry(&1, stubbed))
  end

  defp large_output?(%Entry{payload: %{"output" => output}}, min_bytes) when is_binary(output),
    do: byte_size(output) > min_bytes

  defp large_output?(%Entry{}, _min_bytes), do: false

  defp stub_entry(%Entry{} = entry, stubbed) do
    if MapSet.member?(stubbed, entry.id),
      do: %{entry | payload: stubbed_payload(entry.payload)},
      else: entry
  end

  # The evidence fields go too: they are never sent, and a forecast that
  # measured them would count bytes the request no longer carries. So do
  # attachments: a result stubbed as no longer included cannot still be
  # showing its image.
  defp stubbed_payload(payload) do
    bytes = byte_size(payload["output"])
    name = Map.get(payload, "name", "tool")

    payload
    |> Map.drop(["structured_content", "content", "artifacts", "attachments"])
    |> Map.put(
      "output",
      "[#{bytes} bytes of output from this earlier #{name} call are no longer " <>
        "included; call it again if you still need them]"
    )
  end

  # Deterministic, because a resumed session has to build the request the live
  # one did: the id and time are the first retained message's, never fresh.
  defp continued(entries) do
    case Enum.split_while(entries, &(&1.type not in [:user, :assistant, :tool_result])) do
      {_prefix, []} ->
        entries

      {_prefix, [%Entry{type: :user} | _rest]} ->
        entries

      {prefix, [first | _rest] = rest} ->
        continuation = %Entry{
          id: first.id <> "-continued",
          parent_id: first.parent_id,
          seq: first.seq,
          type: :user,
          payload: %{"text" => @continuation},
          meta: %{"synthetic" => true},
          at: first.at
        }

        prefix ++ [continuation | rest]
    end
  end

  @impl true
  def applied(_state, entries, opts), do: applied(entries, opts)

  defp after_compaction(entries) do
    case newest(entries) do
      nil -> entries
      compaction -> after_cut(entries, compaction)
    end
  end

  # Identity when there is nothing to shed, rather than a rebuilt list that
  # merely equals the old one: callers compare these lists, and one of them
  # compares them for equality.
  defp shed(entries, :all), do: entries

  defp shed(entries, keep) when is_integer(keep) and keep >= 0 do
    kept =
      entries
      |> Enum.filter(&attached?/1)
      |> Enum.take(-keep)
      |> MapSet.new(& &1.id)

    Enum.map(entries, &elide(&1, kept))
  end

  defp attached?(%Entry{type: :user, payload: %{"attachments" => [_ | _]}}), do: true
  defp attached?(%Entry{}), do: false

  defp elide(%Entry{} = entry, kept) do
    if attached?(entry) and not MapSet.member?(kept, entry.id),
      do: %{entry | payload: elided(entry.payload)},
      else: entry
  end

  defp elided(payload) do
    Map.put(payload, "attachments", Enum.map(payload["attachments"], &note/1))
  end

  # String keys the whole way down, because this payload is the same shape the
  # store would have to accept if it ever were written.
  defp note(attachment) do
    path = Map.get(attachment, "path", "")

    %{
      "ref" => Map.get(attachment, "ref", ""),
      "path" => path,
      "kind" => "elided",
      "text" =>
        "<attachment path=\"#{path}\" note=\"attached earlier and no longer included; " <>
          "read the file if you still need it\" />"
    }
  end

  defp after_cut(entries, compaction) do
    to = Map.get(compaction.payload, "to")

    # Everything after the compaction entry itself is always sent; the question is
    # only whether anything *before* it survives. A cut point not on this transcript
    # keeps nothing before the compaction rather than everything: too large a request
    # is a clear error, while a conversation with a hole in the middle is one the
    # model answers confidently and wrong.
    index = Enum.find_index(entries, &(&1.id == compaction.id))
    tail = Enum.drop(entries, index + 1)

    case Enum.find_index(entries, &(&1.id == to)) do
      nil -> tail
      cut when cut < index -> Enum.slice(entries, (cut + 1)..(index - 1)//1) ++ tail
      _otherwise -> tail
    end
  end

  @doc """
  Whether there is still a conversation being sent.

  `applied/1` is never empty in practice — a session records its configuration
  before anything is said — so "is anything being sent" cannot be asked by
  checking whether that list has entries in it. This asks the question the
  caller means: is there a turn left in front of the model. `Lemieux.Session`'s
  `clear/1` uses it to tell an already-clear session from a fresh cut.
  """
  @spec conversation?(entries :: [Entry.t()]) :: boolean()
  def conversation?(entries),
    do: entries |> applied() |> Enum.any?(&(&1.type in @conversational))

  @impl true
  def conversation?(_state, entries), do: conversation?(entries)

  @doc """
  What the newest compaction summarised, or `nil` if there has not been one.
  """
  @spec summary(entries :: [Entry.t()]) :: String.t() | nil
  def summary(entries) do
    case newest(entries) do
      nil -> nil
      compaction -> Map.get(compaction.payload, "summary")
    end
  end

  @impl true
  def summary(_state, entries), do: summary(entries)

  defp newest(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :compaction))
  end

  @doc "The headings the four sections are asked for under, in order."
  @spec section_headings() :: [String.t()]
  def section_headings, do: Enum.map(@sections, &elem(&1, 1))

  @doc """
  The system prompt for the request that produces a summary.

  Given the previous summary, when there is one, so a second compaction does
  not throw away what the first one kept. Without it a long session forgets its
  own beginning one compaction at a time, which is the failure mode that makes
  compaction feel like amnesia rather than like memory.

  ## Options

    * `:sections` — ask for the four structured sections as well. Defaults
      to `false`; see the module documentation for why.
  """
  @spec instructions(previous :: String.t() | nil, opts :: keyword()) :: String.t()
  def instructions(previous \\ nil, opts \\ []) do
    """
    You are summarising the earlier part of a conversation between a person and
    a coding agent, so that the agent can keep working after the earlier part
    stops being sent to it.

    Write the summary for the agent, not for a reader. What matters is what it
    would otherwise have to ask about again:

    - what the person actually asked for, in their words where the wording
      matters, and anything they have since corrected or ruled out;
    - decisions that were made and the reasons, so they are not relitigated;
    - what has been done to the code so far — files created, changed or
      deleted, and what is in them now;
    - what was learned about the codebase that took work to find out;
    - what is still outstanding, and anything that was tried and failed.

    Leave out what the agent can see for itself: the contents of files it can
    read again, and tool output it can reproduce. Do not pad, do not editorialise
    and do not describe the conversation ("the user then asked…") — state the
    facts it needs.

    The most recent part of the conversation is still being sent verbatim, so
    do not summarise the end in detail; it is the beginning and middle that are
    about to disappear.
    """ <> sections_section(Keyword.get(opts, :sections, false)) <> previous_section(previous)
  end

  @impl true
  def instructions(_state, previous, opts), do: instructions(previous, opts)

  defp sections_section(false), do: ""

  # Asked for last, so the prose comes first and the lists are what the
  # answer ends on; and asked for as lists with an explicit empty marker,
  # because a section the model left out and a section with nothing in it
  # would otherwise be the same absence.
  defp sections_section(true) do
    """

    End the summary with these four sections, each under exactly this
    heading and each a list with one item per line, or the single word
    "none" when there is nothing to record:

    ## Open work
    What was asked for and is not yet done, one obligation per line, with
    the acceptance criterion where one was stated.

    ## Dependencies
    What is blocked on what — work waiting on other work, on an answer from
    the person, or on something outside this conversation.

    ## Decisions
    What was decided and why, so it is not decided again.

    ## Verification debt
    What has been changed and not yet checked — tests not run, behaviour
    not exercised, claims not confirmed.
    """
  end

  @doc """
  Reads the four sections back out of a summary.

  `nil` when the summary carries none of the headings — the summariser was
  not asked, or ignored the asking — and otherwise every section, empty
  where the summary had nothing under it or said "none". Items are the
  lines under a heading with their bullet or number removed. Headings are
  matched loosely: `## Open work`, `**Open work:**` and `OPEN WORK` are one
  heading, because the section is worth more than the markup.
  """
  @spec sections(summary :: String.t() | nil) :: sections() | nil
  def sections(nil), do: nil

  def sections(summary) when is_binary(summary) do
    {found, _current} =
      summary
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, fn line, {found, current} ->
        case section_heading(line) do
          nil when is_nil(current) -> {found, nil}
          nil -> {Map.update(found, current, item(line), &(&1 ++ item(line))), current}
          key -> {Map.put_new(found, key, []), key}
        end
      end)

    if map_size(found) == 0,
      do: nil,
      else: Map.new(@sections, fn {key, _heading} -> {key, Map.get(found, key, [])} end)
  end

  @impl true
  def sections(_state, summary), do: sections(summary)

  defp section_heading(line) do
    case Regex.run(@heading, line) do
      [_whole, title] -> heading_key(String.downcase(title))
      nil -> nil
    end
  end

  defp heading_key(title) do
    Enum.find_value(@sections, fn {key, heading} ->
      if String.downcase(heading) == String.trim(title), do: key
    end)
  end

  defp item(line) do
    case line |> String.replace(@bullet, "") |> String.trim() do
      "" -> []
      empty when empty in ["none", "none.", "nothing", "n/a", "-", "—"] -> []
      text -> [text]
    end
  end

  defp previous_section(nil), do: ""

  defp previous_section(previous) do
    """

    This conversation has been summarised before. Here is that summary; fold it
    into yours, so that nothing in it is lost:

    #{previous}
    """
  end

  @doc """
  How a summary is put in front of a request.

  It goes in the **system prompt** rather than in as a message, which is the
  choice worth explaining. As a message it would have to be a user message —
  the summary is not something the model said — and it would land immediately
  before the real prompt that follows the cut, giving two user messages in a
  row. Providers differ on whether they accept that, and the alternative in
  wide use is to fabricate an assistant reply ("Understood.") to separate them,
  which puts words in the model's mouth to work around a formatting rule.

  In the system prompt it is unambiguous, always valid, and reads as what it is:
  context about this conversation rather than a turn in it.
  """
  @spec with_summary(system :: String.t() | nil, summary :: String.t() | nil) ::
          String.t() | nil
  def with_summary(system, nil), do: system

  def with_summary(system, summary) do
    section = """
    <earlier-conversation>
    The beginning of this conversation is no longer being sent to you in full.
    This is a summary of it. Treat it as things you already know and have
    already done, not as something you were told about.

    #{summary}
    </earlier-conversation>
    """

    case system do
      nil -> section
      "" -> section
      system -> system <> "\n\n" <> section
    end
  end

  @impl true
  def with_summary(_state, system, summary), do: with_summary(system, summary)
end
