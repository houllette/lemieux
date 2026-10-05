defmodule CaptureExtension.Draft do
  @moduledoc """
  Turns a session's signals into a feedback record and a frozen draft.

  Two things are written, in this order, and nothing else apart from the
  drafts directory's `.gitignore` described below:

    1. A `Lemieux.Feedback` record, appended through the ordinary feedback
       store — the same record `lmx feedback` writes, with a `hook` actor and
       `capture` host so a reviewer can tell it from a person's complaint. It
       anchors on the triggering entry and carries every detected signal in
       its provenance.

    2. A draft under the drafts directory. A verification failure is
       mechanically verifiable — the failing command *is* the verifier — so
       it goes through `Lemieux.Feedback.CaseDraft` as a `mechanical` case
       whose grader is `sh -c COMMAND` over the frozen workspace. A
       correction has no verifier yet, and `CaseDraft` rightly refuses an
       unclassified record, so it is frozen as a *review draft*: the same
       `fixture/` and `draft.json` layout, marked `needs_review`, with no
       `task` — which is exactly what makes `lmx corpus promote` refuse it
       until a person has run `lmx feedback draft-case` with a prompt, a
       verifier and a class.

  Beside either draft, `capture.json` records the signals, the snapshot
  bounds and everything the snapshot skipped, because a fixture that is
  missing a file is a fixture whose grader may fail for the wrong reason.

  The workspace is copied into a staging directory under the drafts
  directory first, so `CaseDraft` — which copies whatever it is given — only
  ever sees a bounded tree.

  The drafts directory also gets a `.gitignore` of `*` the first time it is
  used, unless it already has one. It usually sits inside the workspace it
  copies (`.lmx/drafts`), and without the file the next `git add -A` in that
  repository stages every draft: whole copies of the working tree, made
  before anyone reviewed them. A draft reaches a corpus through
  `lmx corpus promote`, never by being committed where it was written.
  """

  alias CaptureExtension.Config
  alias CaptureExtension.Signals
  alias CaptureExtension.Snapshot
  alias Lemieux.Entry
  alias Lemieux.Feedback
  alias Lemieux.Feedback.CaseDraft
  alias Lemieux.Feedback.Store, as: FeedbackStore
  alias Lemieux.Feedback.Store.JSONL, as: FeedbackJSONL

  @schema_version 1
  @prompt_limit 2_000
  @excerpt_limit 80

  @type class :: :mechanical | :needs_review

  @type t :: %__MODULE__{
          id: String.t(),
          path: Path.t(),
          feedback_id: String.t(),
          class: class(),
          signal: Signals.t(),
          snapshot: Snapshot.summary(),
          promote: String.t(),
          line: String.t()
        }

  @enforce_keys [:id, :path, :feedback_id, :class, :signal, :snapshot, :promote, :line]
  defstruct [:id, :path, :feedback_id, :class, :signal, :snapshot, :promote, :line]

  @doc """
  Records the feedback and freezes one draft for the session.

  The first signal is the one the draft is about: `Signals.detect/2` lists a
  verification failure first, so a session with both gets the mechanical
  draft and keeps the corrections as evidence in the record.
  """
  @spec write(
          signals :: [Signals.t(), ...],
          entries :: [Entry.t()],
          session :: %{session_id: String.t(), cwd: Path.t()},
          config :: Config.t()
        ) :: {:ok, t()} | {:error, term()}
  def write(
        [primary | _] = signals,
        entries,
        %{session_id: session_id, cwd: cwd},
        %Config{} = config
      )
      when is_list(entries) do
    drafts_dir = Path.expand(config.drafts_dir, cwd)
    store = config.feedback_store || FeedbackJSONL.new(config.feedback_dir)

    with {:ok, feedback} <- feedback(primary, signals, session_id, cwd, config),
         :ok <- FeedbackStore.append(store, feedback),
         :ok <- mkdir(drafts_dir),
         :ok <- ignored(drafts_dir),
         id = "case_" <> String.trim_leading(feedback.id, "fb_"),
         staging = Path.join(drafts_dir, ".staging-" <> id),
         {:ok, snapshot} <- snapshot(cwd, staging, drafts_dir, config),
         {:ok, path} <- freeze(primary, feedback, entries, id, staging, drafts_dir, snapshot) do
      class = class(primary)
      promote = "lmx corpus promote #{path} MANIFEST --cluster CLUSTER"
      line = line(class, path, primary, feedback.id, promote)

      draft = %__MODULE__{
        id: id,
        path: path,
        feedback_id: feedback.id,
        class: class,
        signal: primary,
        snapshot: snapshot,
        promote: promote,
        line: line
      }

      with :ok <- record_capture(draft, signals, session_id, cwd) do
        {:ok, draft}
      end
    end
  end

  defp feedback(primary, signals, session_id, cwd, config) do
    provenance =
      %{
        "host" => "capture",
        "tenant_id" => config.tenant_id,
        "project_id" => cwd,
        "session_id" => session_id,
        "entry_id" => primary.anchor_entry_id,
        "signals" => Enum.map(signals, &signal_map/1)
      }
      |> put_present("tool_call_id", primary.call_id)

    Feedback.new(text(primary), provenance,
      type: type(primary),
      verifiability: verifiability(primary),
      actor: %{"type" => "hook", "id" => "capture-extension"},
      scope: :project
    )
  end

  defp text(%{kind: :verification_failure, command: command, exit_status: status}),
    do: "`#{command}` exited #{status} and no later run passed before the session ended."

  defp text(%{kind: :correction, text: text}),
    do: "Correction after an assistant turn: #{String.slice(text, 0, 300)}"

  defp type(%{kind: :verification_failure}), do: :bug
  defp type(%{kind: :correction}), do: :unknown

  # `source` says who decided the class. A command's exit status decided the
  # mechanical one; nobody has decided the correction's, and the record says
  # so rather than guessing.
  defp verifiability(%{kind: :verification_failure, command: command}),
    do: %{"class" => "mechanical", "source" => "verification_command", "command" => command}

  defp verifiability(%{kind: :correction}),
    do: %{"class" => "unknown", "source" => "user_correction"}

  defp class(%{kind: :verification_failure}), do: :mechanical
  defp class(%{kind: :correction}), do: :needs_review

  defp snapshot(cwd, staging, drafts_dir, config) do
    Snapshot.copy(cwd, staging,
      exclude: [drafts_dir],
      max_file_bytes: config.max_file_bytes,
      max_total_bytes: config.max_total_bytes,
      skip_dirs: config.skip_dirs
    )
  end

  # The staging tree is removed whichever way the freeze went: `CaseDraft`
  # copies it, the review draft renames it, and a failure must not leave a
  # half-built workspace copy beside the drafts.
  defp freeze(primary, feedback, entries, id, staging, drafts_dir, snapshot) do
    result = do_freeze(primary, feedback, entries, id, staging, drafts_dir, snapshot)
    File.rm_rf(staging)
    result
  end

  defp do_freeze(
         %{kind: :verification_failure} = signal,
         feedback,
         entries,
         id,
         staging,
         drafts_dir,
         _snapshot
       ) do
    case CaseDraft.create(feedback, staging, drafts_dir,
           id: id,
           prompt: prompt(entries, signal),
           verifier: ["sh", "-c", signal.command]
         ) do
      {:ok, draft} -> {:ok, Path.dirname(draft.record_path)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_freeze(
         %{kind: :correction} = signal,
         feedback,
         entries,
         id,
         staging,
         drafts_dir,
         snapshot
       ) do
    root = Path.join(drafts_dir, id)

    record = %{
      "schema_version" => @schema_version,
      "id" => id,
      "status" => "draft",
      "needs_review" => true,
      "feedback_id" => feedback.id,
      "fixture_digest" => snapshot["digest"],
      "provenance" => feedback.provenance,
      "feedback" => Feedback.to_map(feedback),
      "suggested_prompt" => prompt(entries, signal),
      "review_checklist" => [
        "decide whether the correction is mechanically verifiable",
        "write a verifier that fails on this fixture and passes once the correction is honoured",
        "run lmx feedback draft-case #{feedback.id} --source #{Path.join(root, "fixture")} with that verifier and a class"
      ]
    }

    with :ok <- unused(root),
         :ok <- mkdir(root),
         :ok <- rename(staging, Path.join(root, "fixture")),
         :ok <- write_json(Path.join(root, "draft.json"), record) do
      {:ok, root}
    end
  end

  defp record_capture(%__MODULE__{} = draft, signals, session_id, cwd) do
    write_json(Path.join(draft.path, "capture.json"), %{
      "schema_version" => @schema_version,
      "session_id" => session_id,
      "cwd" => cwd,
      "class" => Atom.to_string(draft.class),
      "feedback_id" => draft.feedback_id,
      "signal" => signal_map(draft.signal),
      "signals" => Enum.map(signals, &signal_map/1),
      "snapshot" => draft.snapshot,
      "promote" => draft.promote
    })
  end

  # The original task, then the condition the draft adds. A reviewer rewrites
  # this; the point is that the draft is runnable as captured.
  defp prompt(entries, %{kind: :verification_failure, command: command}) do
    task = first_prompt(entries) || "Make the verification pass."
    "#{task}\n\nWhen you are done, `#{command}` must exit 0."
  end

  defp prompt(entries, %{kind: :correction, text: text}) do
    task = first_prompt(entries) || "Address the correction."
    "#{task}\n\nThe person later corrected the assistant: #{inspect(text)}"
  end

  defp first_prompt(entries) do
    Enum.find_value(entries, fn
      %Entry{type: :user, payload: %{"text" => text}} when is_binary(text) ->
        case String.trim(text) do
          "" -> nil
          trimmed -> String.slice(trimmed, 0, @prompt_limit)
        end

      _entry ->
        nil
    end)
  end

  defp line(:mechanical, path, %{command: command, exit_status: status}, _feedback_id, promote) do
    "capture: drafted #{path} (`#{command}` exited #{status}); review it, then: #{promote}"
  end

  defp line(:needs_review, path, %{text: text}, feedback_id, promote) do
    "capture: drafted #{path} for review (correction: #{inspect(excerpt(text))}); " <>
      "classify it with: lmx feedback draft-case #{feedback_id} --source #{Path.join(path, "fixture")} " <>
      "--output DRAFTS --prompt PROMPT --verifier COMMAND --class mechanical, then: #{promote}"
  end

  defp excerpt(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, @excerpt_limit)
  end

  defp signal_map(signal) do
    %{
      "kind" => Atom.to_string(signal.kind),
      "pattern" => signal.pattern,
      "entry_ids" => signal.entry_ids,
      "anchor_entry_id" => signal.anchor_entry_id
    }
    |> put_present("command", signal.command)
    |> put_present("exit_status", signal.exit_status)
    |> put_present("call_id", signal.call_id)
    |> put_present("text", signal.text)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, path, reason}}
    end
  end

  # A `.gitignore` already there is the person's, and is left as it is.
  defp ignored(drafts_dir) do
    path = Path.join(drafts_dir, ".gitignore")

    case File.write(path, "*\n", [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:write, path, reason}}
    end
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename, to, reason}}
    end
  end

  defp write_json(path, map) do
    case File.write(path, JSON.encode!(map)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write, path, reason}}
    end
  end

  defp unused(path),
    do: if(File.exists?(path), do: {:error, {:draft_exists, path}}, else: :ok)
end
