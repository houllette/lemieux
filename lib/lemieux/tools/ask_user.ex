defmodule Lemieux.Tools.AskUser do
  @moduledoc """
  Asks whoever is watching a question, and waits for the answer.

  The tool that makes "I do not know which of these you meant" a thing an
  agent can say in the middle of its work, rather than a guess it commits to
  and builds on for the rest of the session.

  ## Not in the default set

  `Lemieux.Tools.default/0` does not include it, and hosts opt in. Two
  reasons, and the second is the real one:

    * Every tool is a permanent tax on the prompt of every session.
    * **A session with nobody attached cannot answer.** Offering the tool to a
      headless run invites the model to stop and wait for a person who does
      not exist. The timeout means it recovers rather than hanging, but it has
      still spent a turn and some minutes learning that. `lmx` gives this tool
      to the TUI, where there is somebody to ask, and withholds it from
      `lmx run`, where there is not.

  A host whose headless sessions *do* have somewhere to put a question — an
  inbox, a ticket, a person on a phone — should add it. That is the whole
  reason the decision belongs to the host.

  ## How the waiting works

  `Lemieux.Session.park/4` blocks this task, not the session: the session goes
  on answering snapshots, steers and cancels while the question stands, and
  the answer arrives through `Lemieux.Session.answer/3`. The turn resumes with
  the answer as this call's result, which is the ordinary tool-result path and
  needs nothing special from the model.
  """

  @behaviour Lemieux.Tool

  alias Lemieux.Session
  alias Lemieux.Tools.AskUser.Diagram
  alias Lemieux.Tools.AskUser.Questionnaire

  @max_options 6

  @impl Lemieux.Tool
  def name, do: "ask_user"

  @impl Lemieux.Tool
  def description do
    """
    Ask the person you are working with a question, and wait for their answer.

    Use it when the work cannot sensibly continue until you know something \
    only they can tell you — which of two files they meant, whether a \
    destructive change is intended, which approach they prefer. Do not use it \
    for things you can find out yourself by reading the repository.

    Send either `questions` or a single `question`, never both. \
    Prefer the `questions` array, even for one question. Example: \
    {"questions":[{"id":"approach","question":"Which approach?", \
    "type":"single_choice","options":[{"id":"a","label":"Reuse"}, \
    {"id":"b","label":"Replace"}]}]}. Give each question nonempty text \
    and each choice or ranking option a label; send 2–6 options. Short unique \
    ids help interpret answers and are assigned by position when omitted. \
    Never include Other; the \
    UI adds it for choice questions. For free-form input use `type`: `text` \
    or `number` and omit `options` entirely. Valid types are `single_choice` \
    (default), `multi_select`, `ranking`, `text`, and `number`. \
    Ranking returns option ids in priority order and has no Other slot. \
    Choice questions offer Other. Batches support previews and notes; notes \
    on multi_select and ranking apply to the entire question. \
    Put a small plain-text diagram on each suggestion when a visual example helps; \
    tailor that diagram to its suggestion. A question-level diagram may show \
    context shared by all choices.

    Nobody may be attached, in which case you will be told so and should carry \
    on as best you can.
    """
  end

  @impl Lemieux.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "questions" =>
          Map.put(
            Questionnaire.schema(),
            "description",
            "Preferred form: 1–4 questions. Give each a question; choice/ranking options each need a label. Unique ids are recommended and assigned when omitted."
          ),
        "question" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "The question, in one or two sentences."
        },
        "diagram" => Diagram.schema(),
        "type" => %{
          "type" => "string",
          "enum" => ~w(single_choice multi_select ranking text number)
        },
        "options" => %{
          "type" => "array",
          "minItems" => 2,
          "maxItems" => @max_options,
          "description" => "Two to six suggested answers for choice or ranking questions.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "label" => %{
                "type" => "string",
                "minLength" => 1,
                "description" =>
                  "The short answer returned when chosen. Do not include Other; the UI adds it."
              },
              "description" => %{
                "type" => "string",
                "minLength" => 1,
                "description" => "A short explanation of this option's tradeoff."
              },
              "diagram" => Diagram.schema()
            },
            "required" => ["label"],
            "additionalProperties" => false
          }
        }
      },
      # OpenAI and Anthropic reject top-level tool-schema combinators: the
      # former oneOf made even a greeting through Ixway fail with HTTP 400.
      # run/2 enforces exactly one question form, preserving both calling
      # conventions without making the entire model request invalid.
      "additionalProperties" => false
    }
  end

  # The bundled front ends intentionally present one question at a time. Two
  # simultaneous questions used to overwrite the first call id in a host, so the
  # answer was sent to the wrong parked call. Serialising is a small attention cost
  # and preserves the provider rule that every call is answered before the wave
  # continues.
  @impl Lemieux.Tool
  def parallel_safe?, do: false

  @impl Lemieux.Tool
  def metadata do
    %{
      effects: %{class: "attention", resource_types: ["human_attention"]},
      policy: %{requires_human_channel: true},
      runtime: %{timeout_ms: :timer.minutes(5), concurrency: %{class: "exclusive"}}
    }
  end

  @impl Lemieux.Tool
  def run(%{"questions" => questions} = args, context) do
    cond do
      Map.has_key?(args, "question") ->
        {:error, "ask_user accepts question or questions, not both"}

      Map.has_key?(args, "diagram") ->
        {:error, "put a diagram on its question inside questions"}

      Map.has_key?(args, "type") or Map.has_key?(args, "options") ->
        {:error, "put type and options on each question inside questions"}

      true ->
        Questionnaire.run(questions, context)
    end
  end

  def run(%{"question" => question, "type" => type} = args, context)
      when is_binary(question) and question != "" and type in ~w(multi_select ranking text number) do
    options =
      case Map.get(args, "options", []) do
        options when is_list(options) ->
          options
          |> Enum.with_index(1)
          |> Enum.map(fn
            {option, index} when is_map(option) -> Map.put(option, "id", Integer.to_string(index))
            {option, _index} -> option
          end)

        invalid ->
          invalid
      end

    Questionnaire.run(
      [
        %{
          "id" => "answer",
          "question" => question,
          "type" => type,
          "options" => options,
          "diagram" => Map.get(args, "diagram")
        }
      ],
      context
    )
  end

  def run(%{"question" => question, "options" => raw_options} = args, context)
      when is_binary(question) and question != "" do
    with true <- Map.get(args, "type", "single_choice") == "single_choice",
         {:ok, options} <- options(raw_options),
         {:ok, diagram} <- Diagram.normalize(Map.get(args, "diagram")) do
      Session.park(context.session, context.call_id, :question, %{
        call_id: context.call_id,
        question: question,
        diagram: diagram,
        options: options,
        ask_user: true
      })
    else
      false -> {:error, "invalid ask_user question type"}
      error -> error
    end
  end

  def run(_args, _context),
    do:
      {:error,
       "ask_user needs a question and two to six suggested answers, or a valid text/number type"}

  defp options(options) when is_list(options) and length(options) in 2..@max_options do
    options
    |> Enum.reduce_while({:ok, []}, fn option, {:ok, acc} ->
      case option(option) do
        {:ok, option} -> {:cont, {:ok, [option | acc]}}
        :error -> {:halt, {:error, options_error()}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp options(_options), do: {:error, options_error()}

  defp option(%{"label" => label} = option) when is_binary(label) do
    with label when label != "" <- String.trim(label),
         false <- String.downcase(label) == "other",
         {:ok, description} <- description(Map.get(option, "description")),
         {:ok, diagram} <- Diagram.normalize(Map.get(option, "diagram")) do
      {:ok, %{label: label, description: description, diagram: diagram}}
    else
      _invalid -> :error
    end
  end

  defp option(_option), do: :error

  defp description(nil), do: {:ok, nil}

  defp description(description) when is_binary(description) do
    case String.trim(description) do
      "" -> :error
      description -> {:ok, description}
    end
  end

  defp description(_description), do: :error

  defp options_error,
    do: "ask_user options need two to six non-empty labels and optional descriptions"
end
