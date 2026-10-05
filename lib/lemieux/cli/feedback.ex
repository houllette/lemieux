defmodule Lemieux.CLI.Feedback do
  @moduledoc """
  Standalone anchored feedback capture.

  This command reads a transcript to resolve the session and selected entry,
  then writes to the dedicated feedback ledger. It never appends a conversation
  entry. Classification and case approval are later, separately authorized
  revisions; capture only preserves what the person said and where they said
  it about.
  """

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Feedback, as: FeedbackRecord
  alias Lemieux.Feedback.CaseDraft
  alias Lemieux.Feedback.Dialogue
  alias Lemieux.Feedback.Store, as: FeedbackStore
  alias Lemieux.Feedback.Store.JSONL, as: FeedbackJSONL
  alias Lemieux.ID.Shorthand
  alias Lemieux.Reflection.Opportunities
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Transcript

  @switches [
    sessions_dir: :string,
    feedback_dir: :string,
    text: :string,
    entry: :string,
    scope: :string,
    standing_rule: :boolean,
    mine: :boolean,
    model: :string,
    max_tokens: :integer,
    reasoning_effort: :string
  ]
  @scopes %{"task" => :task, "project" => :project, "tenant" => :tenant, "global" => :global}

  @doc """
  Captures feedback without halting the VM.

  `--mine` runs a bounded, tool-less reflection over the stored transcript
  and records each opportunity the model names as a feedback record with a
  model actor and `reflection` provenance. Mined records enter the same
  triage and case-draft path as a person's feedback and never become assets
  on their own. The model connection is the ordinary CLI one, or `--model`.
  """
  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(["draft-case" | argv], opts), do: draft_case(argv, opts)

  def run(argv, opts) do
    case parse(argv) do
      {:ok, parsed, rest} ->
        if parsed[:mine], do: mine(parsed, rest, opts), else: capture(parsed, rest, opts)

      {:error, reason} ->
        fail(describe(reason))
    end
  end

  @draft_switches [
    sessions_dir: :string,
    feedback_dir: :string,
    source: :string,
    output: :string,
    prompt: :string,
    verifier: :string,
    class: :string
  ]

  # `lmx feedback draft-case ID --source DIR --output DIR --prompt P --verifier CMD
  # [--class mechanical]` freezes a fixture and a verifier beside a feedback
  # record. `--class` records the reviewer's verifiability judgment as a revision
  # first, which is what makes a mined or unclassified record eligible; the draft
  # stays a draft until `lmx corpus promote` moves it, after review.
  defp draft_case(argv, opts) do
    with {:ok, parsed, [id]} <- parse_draft(argv),
         {:ok, source} <- required(parsed, :source),
         {:ok, output} <- required(parsed, :output),
         {:ok, prompt} <- required(parsed, :prompt),
         {:ok, verifier} <- required(parsed, :verifier),
         store = feedback_store(parsed, opts),
         {:ok, feedback} <- FeedbackStore.latest(store, id),
         {:ok, feedback} <- classify(feedback, parsed[:class], store, opts),
         {:ok, draft} <-
           CaseDraft.create(feedback, source, output,
             prompt: prompt,
             verifier: OptionParser.split(verifier)
           ) do
      IO.puts("drafted case #{draft.id} at #{Path.dirname(draft.record_path)}")
      Enum.each(draft.review_checklist, &IO.puts("  review: #{&1}"))

      IO.puts(
        "  then: lmx corpus promote #{Path.dirname(draft.record_path)} MANIFEST --cluster ID"
      )

      :ok
    else
      {:ok, _parsed, _rest} ->
        fail("draft-case needs exactly one feedback id")

      {:error, {:not_case_eligible, class}} ->
        fail(
          "feedback is #{inspect(class)}; pass --class mechanical or --class environmental after reviewing it"
        )

      {:error, reason} ->
        fail(describe(reason))
    end
  end

  defp parse_draft(argv) do
    case OptionParser.parse(argv, strict: @draft_switches) do
      {parsed, rest, []} -> {:ok, parsed, rest}
      {_parsed, _rest, [{flag, _value} | _]} -> {:error, {:invalid_option, flag}}
    end
  end

  defp required(parsed, key) do
    case Keyword.get(parsed, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing_option, key}}
    end
  end

  defp classify(feedback, nil, _store, _opts), do: {:ok, feedback}

  defp classify(feedback, class, store, opts) when class in ["mechanical", "environmental"] do
    interpretation = %{
      "kind" => "verifiability",
      "class" => class,
      "actor" => Keyword.get(opts, :actor, %{"type" => "human", "id" => "local"}),
      "questions_asked" => 0
    }

    with {:ok, revised} <-
           FeedbackRecord.revise(feedback, interpretation,
             verifiability: %{"class" => class},
             status: :triaged
           ),
         :ok <- FeedbackStore.append(store, revised) do
      {:ok, revised}
    end
  end

  defp classify(_feedback, class, _store, _opts), do: {:error, {:invalid_class, class}}

  @doc """
  Appends one anchored feedback record to the ledger.

  The one write path both entry points use. `lmx feedback` resolves a session
  and an anchor from flags; the in-session `/feedback` flow resolves them from
  the conversation a person is already in — and then both arrive here, so a
  record captured mid-session is indistinguishable from one captured
  afterwards apart from the answers it carries. A second implementation would
  have been a second place for the ledger's shape, its provenance fields and
  its question cap to drift.

  `submission` carries `:text`, `:session_id` and `:entry_id`, and optionally
  `:type`, `:scope`, `:durability` and `:questions_asked`. Answers a person
  gave to clarification questions are recorded as one interpretation revision
  rather than folded silently into the record, so the ledger says the routing
  fields were asked for rather than inferred. `Lemieux.Feedback.revise/3`
  refuses more than three.

  Options: `:feedback_store` (or `:sessions_dir` and `:feedback_dir` to build
  the default one), `:tenant_id`, `:project_id`, `:actor` and `:host`.
  """
  @spec capture(submission :: map(), opts :: keyword()) ::
          {:ok, Lemieux.Feedback.t()} | {:error, term()}
  def capture(submission, opts \\ []) when is_map(submission) and is_list(opts) do
    store = Keyword.get_lazy(opts, :feedback_store, fn -> feedback_store([], opts) end)

    # Both revisions are appended, in order. The ledger is append-only and refuses a
    # first line that is not revision one, and that rule is worth keeping: the first
    # line is what the person actually said, and the second is what was made of it.
    with {:ok, captured} <- record(submission, opts),
         :ok <- FeedbackStore.append(store, captured),
         {:ok, feedback} <- asked(captured, submission, opts),
         :ok <- appended(store, captured, feedback) do
      {:ok, feedback}
    end
  end

  defp appended(_store, captured, captured), do: :ok
  defp appended(store, _captured, revised), do: FeedbackStore.append(store, revised)

  defp record(submission, opts) do
    provenance = %{
      "host" => Keyword.get(opts, :host, "standalone"),
      "tenant_id" => Keyword.get(opts, :tenant_id, "local"),
      "project_id" => Keyword.get(opts, :project_id, File.cwd!()),
      "session_id" => Map.fetch!(submission, :session_id),
      "entry_id" => Map.fetch!(submission, :entry_id)
    }

    FeedbackRecord.new(Map.fetch!(submission, :text), provenance,
      type: Map.get(submission, :type, :unknown),
      scope: Map.get(submission, :scope, :project),
      durability: Map.get(submission, :durability, :one_off),
      actor: Keyword.get(opts, :actor, %{"type" => "human", "id" => "local"})
    )
  end

  # No questions, no revision: `lmx feedback` reads its routing from flags and
  # has nobody to ask, and an empty interpretation would claim otherwise.
  defp asked(feedback, %{questions_asked: count}, opts) when is_integer(count) and count > 0 do
    interpretation = %{
      "kind" => "capture_answers",
      "actor" => Keyword.get(opts, :actor, %{"type" => "human", "id" => "local"}),
      "questions_asked" => count,
      "answers" => %{
        "type" => Atom.to_string(feedback.type),
        "scope" => Atom.to_string(feedback.scope),
        "durability" => Atom.to_string(feedback.durability)
      }
    }

    FeedbackRecord.revise(feedback, interpretation, status: :triaged)
  end

  defp asked(feedback, _submission, _opts), do: {:ok, feedback}

  defp capture(parsed, rest, opts) do
    with {:ok, reference} <- session_reference(rest),
         {:ok, scope} <- scope(parsed[:scope]),
         {:ok, raw_text} <- raw_text(parsed[:text]),
         transcript_store = transcript_store(parsed, opts),
         {:ok, session_id} <- resolve(transcript_store, reference),
         {:ok, entries} <- read(transcript_store, session_id),
         {:ok, entry} <- select_entry(entries, parsed[:entry]),
         submission = %{
           text: raw_text,
           session_id: session_id,
           entry_id: entry.id,
           scope: scope,
           durability: if(parsed[:standing_rule], do: :standing_rule, else: :one_off)
         },
         {:ok, feedback} <-
           capture(submission, Keyword.put(opts, :feedback_store, feedback_store(parsed, opts))) do
      IO.puts("feedback #{feedback.id} captured")
    else
      {:error, status} when is_integer(status) -> {:error, status}
      {:error, reason} -> fail(describe(reason))
    end
  end

  defp mine(parsed, rest, opts) do
    with {:ok, reference} <- session_reference(rest),
         transcript_store = transcript_store(parsed, opts),
         {:ok, session_id} <- resolve(transcript_store, reference),
         {:ok, entries} <- read(transcript_store, session_id),
         {:ok, entry} <- select_entry(entries, nil),
         {:ok, provider, model} <- connection(parsed, opts),
         {:ok, opportunities, observation} <-
           Opportunities.mine(
             entries,
             [
               provider: provider,
               model: model,
               sessions_dir: parsed[:sessions_dir] || Options.default_sessions_dir()
             ] ++ mine_tuning(parsed)
           ),
         {:ok, ids} <-
           Opportunities.record(
             opportunities,
             %{
               "tenant_id" => Keyword.get(opts, :tenant_id, "local"),
               "project_id" => Keyword.get(opts, :project_id, File.cwd!()),
               "session_id" => session_id
             },
             feedback_store(parsed, opts),
             model: model,
             fallback_entry_id: entry.id
           ) do
      IO.puts("mined #{length(ids)} opportunities from #{session_id}")
      Enum.each(ids, &IO.puts("  feedback #{&1}"))

      if ids == [],
        do: IO.puts("  reflection answer: #{String.slice(observation["answer"] || "", 0, 400)}")

      :ok
    else
      {:error, status} when is_integer(status) -> {:error, status}
      {:error, reason} -> fail(describe(reason))
    end
  end

  # `--max-tokens` and `--reasoning-effort` reach the reflection session directly.
  # The reflection is one tool-less request whose whole job is to emit a JSON
  # array, and a reasoning model spends its output budget thinking first — so the
  # module default is generous, and these raise it further for a long transcript.
  # Absent options are not passed, so that default stands.
  defp mine_tuning(parsed) do
    Enum.reduce([:max_tokens, :reasoning_effort], [], fn key, acc ->
      case Keyword.fetch(parsed, key) do
        {:ok, value} -> [{key, value} | acc]
        :error -> acc
      end
    end)
  end

  # The mining connection is the ordinary CLI provider so routing, keys and
  # `--model` behave as they do everywhere else; tests inject `:provider`.
  defp connection(parsed, opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} ->
        {:ok, provider, parsed[:model] || Keyword.get(opts, :model, "test:model")}

      :error ->
        argv = if parsed[:model], do: ["--model", parsed[:model]], else: []

        with {:ok, options} <- Options.parse(argv) do
          {:ok, Runtime.provider(options), options.model}
        end
    end
  end

  defp parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {parsed, rest, []} -> {:ok, parsed, rest}
      {_parsed, _rest, [{flag, _value} | _]} -> {:error, {:invalid_option, flag}}
    end
  end

  defp session_reference([reference]), do: {:ok, reference}
  defp session_reference(_rest), do: {:error, :session_required}

  defp scope(nil), do: {:ok, :project}

  defp scope(value) do
    case Map.fetch(@scopes, value) do
      {:ok, scope} -> {:ok, scope}
      :error -> {:error, {:invalid_scope, value}}
    end
  end

  defp raw_text(value) when is_binary(value) and value != "", do: {:ok, value}

  defp raw_text(nil) do
    case IO.gets("Feedback: ") do
      :eof -> {:error, :feedback_required}
      {:error, reason} -> {:error, {:input, reason}}
      text -> raw_text(String.trim(text))
    end
  end

  defp raw_text(_value), do: {:error, :feedback_required}

  defp resolve(store, reference), do: Shorthand.resolve(store, reference)

  defp read(store, session_id), do: Store.read(store, session_id)

  defp select_entry([], _requested), do: {:error, :empty_session}
  defp select_entry(entries, nil), do: {:ok, List.last(entries)}

  defp select_entry(entries, requested) do
    case Enum.find(entries, &(&1.id == requested)) do
      nil -> {:error, {:entry_not_found, requested}}
      entry -> {:ok, entry}
    end
  end

  defp transcript_store(parsed, opts) do
    Keyword.get_lazy(opts, :store, fn ->
      JSONL.new(parsed[:sessions_dir] || Options.default_sessions_dir())
    end)
  end

  @doc """
  The entries a `/feedback` dialogue offers, from a session snapshot.

  A thin pass-through to `Lemieux.Feedback.Dialogue.anchors/1`, here so an
  interactive front end has one call to make and no opinion of its own about
  which entries a person can point at.
  """
  @spec anchors(snapshot :: map()) :: [Dialogue.anchor()]
  def anchors(%{entries: entries}), do: Dialogue.anchors(entries)

  @doc """
  Records the opportunities in a finished `/reflect opportunities` answer.

  `lmx feedback --mine` runs its own bounded reflection session and then
  records what came back; in an interactive session the reflection has already
  run, streamed to the person, and been persisted, so there is nothing left to
  pay for — only the answer to read. Both paths end at
  `Lemieux.Reflection.Opportunities.record/4`, so a mined record from inside a
  session is the same record with the same model actor and the same
  `reflection` provenance, and lands in the same ledger.

  An answer that was prose rather than JSON is not a failure; it is zero
  opportunities, and `{:ok, []}` says so.

  Options: `:feedback_store` (or `:sessions_dir`/`:feedback_dir`),
  `:tenant_id`, `:project_id` and `:scope`.
  """
  @spec harvest(snapshot :: map(), opts :: keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def harvest(%{entries: entries, id: session_id} = snapshot, opts \\ []) do
    answer =
      case Transcript.latest_assistant_text(entries) do
        {:ok, text} -> text
        {:error, :not_found} -> nil
      end

    provenance = %{
      "tenant_id" => Keyword.get(opts, :tenant_id, "local"),
      "project_id" => Keyword.get(opts, :project_id, File.cwd!()),
      "session_id" => session_id
    }

    fallback = entries |> List.last() |> then(&(&1 && &1.id))

    answer
    |> Opportunities.parse()
    |> Opportunities.record(provenance, feedback_store([], opts),
      model: Map.get(snapshot, :model, "unknown"),
      fallback_entry_id: fallback,
      scope: Keyword.get(opts, :scope, :project)
    )
  end

  @doc """
  The feedback ledger a set of options names, built the same way everywhere.

  The ledger sits beside the sessions directory rather than inside it, because
  a complaint about a run is not part of that run's transcript. Public so an
  interactive host can hand the same store to `capture/2` that `lmx feedback`
  would have used, instead of deriving the path a second time and writing a
  second ledger next to the first.
  """
  @spec store(opts :: keyword()) :: FeedbackStore.t()
  def store(opts \\ []) when is_list(opts), do: feedback_store([], opts)

  defp feedback_store(parsed, opts) do
    Keyword.get_lazy(opts, :feedback_store, fn ->
      sessions = parsed[:sessions_dir] || opts[:sessions_dir] || Options.default_sessions_dir()

      directory =
        parsed[:feedback_dir] || opts[:feedback_dir] ||
          Path.join(Path.dirname(sessions), "feedback")

      FeedbackJSONL.new(directory)
    end)
  end

  defp describe(:session_required),
    do: "feedback needs a session id: lmx feedback SESSION, or lmx feedback --mine SESSION"

  defp describe(:feedback_required), do: "feedback text cannot be empty"
  defp describe(:not_found), do: "no such session"
  defp describe(:empty_session), do: "the session has no entries to anchor"
  defp describe({:entry_not_found, id}), do: "no entry #{id} in that session"
  defp describe({:invalid_option, flag}), do: "unrecognised feedback option #{flag}"
  defp describe({:invalid_scope, scope}), do: "unknown feedback scope #{inspect(scope)}"
  defp describe({:missing_option, key}), do: "draft-case needs --#{key}"
  defp describe({:invalid_class, class}), do: "unknown verifiability class #{inspect(class)}"
  defp describe(reason), do: "could not capture feedback: #{inspect(reason)}"

  defp fail(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 1}
  end
end
