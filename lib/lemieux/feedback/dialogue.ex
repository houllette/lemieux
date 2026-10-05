defmodule Lemieux.Feedback.Dialogue do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  The question-and-answer flow behind `/feedback`, with nothing about a screen.

  Capturing feedback in-session is a short conversation of its own: which
  moment is this about, what should have happened, and the few facts that
  decide where the record goes. Those decisions are identical in the TUI and
  in an interactive host, so they live here for the same reason `Lemieux.Conversation`
  exists — a flow implemented twice is a flow that answers differently twice,
  and the ledger would then hold records whose anchors depended on which front
  end someone happened to be using.

  It is a pure fold. `open/2` starts a dialogue over the anchors a front end
  read from its own session, `answer/2` folds one typed line into it, and the
  dialogue ends by handing back a submission the host writes to the feedback
  ledger. Nothing here reads a store, starts a turn, or appends to a
  transcript.

  ## Why capture never touches the transcript

  A complaint is evidence *about* a run, not another instruction inside it.
  `Lemieux.Feedback` explains the durable half of that decision; this module
  is the interactive half, and the rule shows up here as an absence: no step
  produces a prompt, a steer, or an entry. What a person types while capturing
  feedback reaches the ledger and nothing else, so resume and replay of the
  session are byte-for-byte what they would have been.

  ## Three questions, and why exactly these

  After the anchor and the prose, the dialogue asks at most three questions,
  and `Lemieux.Feedback.revise/3` refuses a fourth. The limit is not a style
  choice: an interrogation after every complaint trains people to stop
  complaining, and the ledger's value is entirely in how much of it gets
  written. So a question earns its place only by changing what happens to the
  record:

    * **type** decides whether this can become a mechanical case at all — a
      bug and a taste preference take different paths and no amount of later
      classification recovers the distinction from prose;
    * **scope** decides how far a resulting rule would reach, and a project
      rule applied tenant-wide is a worse outcome than no rule;
    * **durability** separates "this run went wrong" from "always do it this
      way", which is the difference between a case and a standing instruction.

  Everything else — severity, priority, which file, what the model should have
  said — is either already in the prose or is a judgment for review, and is
  not asked for here.

  Every question takes a number, a word, or a blank line for its default, and
  an unrecognised answer re-asks rather than guessing. The raw prose is never
  edited, reworded or summarised: `Lemieux.Feedback` keeps it exactly as
  typed, and this module hands it over exactly as typed.
  """

  alias Lemieux.Entry

  @anchor_types [:user, :assistant, :tool_result, :error, :compaction, :cancelled]
  @max_anchors 10
  @questions [:type, :scope, :durability]

  @choices %{
    type: [
      {:bug, "bug", "it did something wrong"},
      {:missed_requirement, "missed", "it left out something asked for"},
      {:product_requirement, "product", "it needs a capability it does not have"},
      {:style_preference, "style", "it works, but not the way you want it"},
      {:taste, "taste", "a judgment call you would have made differently"}
    ],
    scope: [
      {:task, "task", "this piece of work only"},
      {:project, "project", "this repository"},
      {:tenant, "tenant", "everyone in your organisation"},
      {:global, "global", "everywhere"}
    ],
    durability: [
      {:one_off, "once", "this run went wrong"},
      {:standing_rule, "always", "a rule for every run from now on"}
    ]
  }

  @defaults %{type: :unknown, scope: :project, durability: :one_off}

  @typedoc "One transcript entry a person can point at."
  @type anchor :: %{id: String.t(), seq: non_neg_integer(), label: String.t()}

  @typedoc "What the host writes to the feedback ledger."
  @type submission :: %{
          text: String.t(),
          entry_id: String.t(),
          type: atom(),
          scope: atom(),
          durability: atom(),
          questions_asked: non_neg_integer()
        }

  @type step :: :text | :anchor | :type | :scope | :durability

  @type t :: %__MODULE__{
          step: step(),
          text: String.t() | nil,
          anchors: [anchor()],
          anchor: anchor() | nil,
          type: atom(),
          scope: atom(),
          durability: atom(),
          asked: non_neg_integer()
        }

  defstruct step: :text,
            text: nil,
            anchors: [],
            anchor: nil,
            type: :unknown,
            scope: :project,
            durability: :one_off,
            # How many of the three clarification questions have been answered.
            # Carried into the record so the ledger says how it was obtained.
            asked: 0

  @doc """
  The entries a person can anchor feedback to, newest first.

  Shared rather than reimplemented per front end so the numbered list a person
  chooses from — and therefore the anchor their record carries — is the same
  in the TUI. Only entries a person can recognise are
  offered: a request or a harness snapshot is real transcript history but
  nobody points at one when saying what went wrong.
  """
  @spec anchors(entries :: [Entry.t()]) :: [anchor()]
  def anchors(entries) when is_list(entries) do
    entries
    |> Enum.filter(&(&1.type in @anchor_types))
    |> Enum.reverse()
    |> Enum.take(@max_anchors)
    |> Enum.map(&%{id: &1.id, seq: &1.seq, label: label(&1)})
  end

  @doc """
  Starts a dialogue over `anchors`.

  `:text` supplies the prose up front, as `/feedback it should have run the
  formatter` does, and the dialogue skips straight to the anchor. A session
  with nothing a person could point at cannot carry anchored feedback at all,
  and says so rather than inventing an anchor.
  """
  @spec open(anchors :: [anchor()], opts :: keyword()) ::
          {:ok, t()} | {:error, :nothing_to_anchor}
  def open(anchors, opts \\ [])

  def open([], _opts), do: {:error, :nothing_to_anchor}

  def open(anchors, opts) when is_list(anchors) and is_list(opts) do
    dialogue = %__MODULE__{anchors: anchors}

    case Keyword.get(opts, :text) do
      text when is_binary(text) and text != "" ->
        {:ok, %{dialogue | text: text, step: :anchor}}

      _absent ->
        {:ok, dialogue}
    end
  end

  @doc "The question the dialogue is waiting on, ready to be shown."
  @spec question(dialogue :: t()) :: String.t()
  def question(%__MODULE__{step: :text}),
    do: "What should have gone differently? (/cancel to stop)"

  def question(%__MODULE__{step: :anchor, anchors: anchors}) do
    listed =
      anchors
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {anchor, index} -> "  #{index}. #{anchor.label}" end)

    "Which moment is this about? (blank for the most recent)\n" <> listed
  end

  def question(%__MODULE__{step: step}) when step in @questions do
    listed =
      @choices
      |> Map.fetch!(step)
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{_value, word, detail}, index} ->
        "  #{index}. #{word} — #{detail}"
      end)

    heading(step) <> "\n" <> listed
  end

  @doc """
  Folds one typed line into the dialogue.

  Returns `{:ask, dialogue}` when there is another question,
  `{:retry, dialogue, message}` when the answer was not one of the offered
  ones, and `{:done, submission}` when the record is ready to write. A blank
  line takes the default at every step except the prose, which cannot be
  empty — a feedback record with no words in it is not evidence of anything.
  """
  @spec answer(dialogue :: t(), line :: String.t()) ::
          {:ask, t()} | {:retry, t(), String.t()} | {:done, submission()}
  def answer(%__MODULE__{} = dialogue, line) when is_binary(line),
    do: step(dialogue, String.trim(line))

  defp step(%__MODULE__{step: :text} = dialogue, "") do
    {:retry, dialogue, "feedback needs some words; /cancel to stop"}
  end

  defp step(%__MODULE__{step: :text} = dialogue, text),
    do: {:ask, %{dialogue | text: text, step: :anchor}}

  defp step(%__MODULE__{step: :anchor, anchors: [newest | _rest]} = dialogue, ""),
    do: {:ask, %{dialogue | anchor: newest, step: :type}}

  defp step(%__MODULE__{step: :anchor, anchors: anchors} = dialogue, line) do
    case Integer.parse(line) do
      {index, ""} when index > 0 and index <= length(anchors) ->
        {:ask, %{dialogue | anchor: Enum.at(anchors, index - 1), step: :type}}

      _not_a_choice ->
        {:retry, dialogue, "choose 1 to #{length(anchors)}, or leave it blank"}
    end
  end

  defp step(%__MODULE__{step: step} = dialogue, line) when step in @questions do
    case choose(step, line) do
      {:ok, value} -> advance(dialogue, step, value)
      :error -> {:retry, dialogue, "choose one of the listed answers, or leave it blank"}
    end
  end

  # A blank line is an answer — the default — and still counts as a question
  # asked, because it was asked. Counting only the non-blank ones would let a
  # flow ask four questions and record three.
  defp advance(dialogue, step, value) do
    dialogue = dialogue |> Map.put(step, value) |> Map.update!(:asked, &(&1 + 1))

    case Enum.drop_while(@questions, &(&1 != step)) do
      [_current, next | _rest] -> {:ask, %{dialogue | step: next}}
      _last -> {:done, submission(dialogue)}
    end
  end

  defp submission(%__MODULE__{} = dialogue) do
    %{
      text: dialogue.text,
      entry_id: dialogue.anchor.id,
      type: dialogue.type,
      scope: dialogue.scope,
      durability: dialogue.durability,
      questions_asked: dialogue.asked
    }
  end

  defp choose(step, ""), do: {:ok, Map.fetch!(@defaults, step)}

  defp choose(step, line) do
    choices = Map.fetch!(@choices, step)
    normalized = String.downcase(line)

    named =
      Enum.find(choices, fn {value, word, _detail} ->
        word == normalized or Atom.to_string(value) == normalized
      end)

    if named, do: {:ok, elem(named, 0)}, else: by_index(choices, normalized)
  end

  defp by_index(choices, line) do
    case Integer.parse(line) do
      {index, ""} when index > 0 and index <= length(choices) ->
        {:ok, choices |> Enum.at(index - 1) |> elem(0)}

      _not_a_choice ->
        :error
    end
  end

  defp heading(:type), do: "What kind of feedback is this? (blank to leave it unclassified)"
  defp heading(:scope), do: "How far does it reach? (blank for this project)"
  defp heading(:durability), do: "Once, or always? (blank for once)"

  defp label(%Entry{type: type, seq: seq} = entry),
    do: "##{seq} #{type} · #{preview(entry)}"

  defp preview(%Entry{type: :user, payload: payload}), do: excerpt(payload["text"])

  defp preview(%Entry{type: :assistant, payload: payload}) do
    payload
    |> Map.get("content", [])
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
    |> Enum.map_join(" ", &Map.get(&1, "text", ""))
    |> excerpt()
  end

  defp preview(%Entry{type: :tool_result, payload: payload}) do
    marker = if payload["error"] == true, do: "✗", else: "✓"
    excerpt("#{marker} #{payload["name"]} #{payload["output"]}")
  end

  defp preview(%Entry{type: :error, payload: payload}), do: excerpt(payload["reason"])
  defp preview(%Entry{payload: payload}), do: payload |> inspect() |> excerpt()

  defp excerpt(value) when is_binary(value) do
    value
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 70)
    |> String.trim()
  end

  defp excerpt(_value), do: ""
end
