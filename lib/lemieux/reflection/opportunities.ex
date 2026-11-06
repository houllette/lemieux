defmodule Lemieux.Reflection.Opportunities do
  @moduledoc """
  **Experimental.** Not part of the stable public API.
  Mines a transcript for opportunities and records them as feedback, never as
  assets.

  `/reflect` produces prose a person reads. This module produces the same
  kind of assessment as structured records that can enter the case-draft path:
  each opportunity names its evidence entries, claims a verifiability class,
  and may propose a mechanical case. RHO shows self-preference can be trusted
  when it is grounded in re-solving real past failures; Prime Agent's Factorio
  incident shows what happens when trajectory-mined lessons skip the case
  gate. So a mined opportunity is a `Lemieux.Feedback` record with a model
  actor and `reflection` provenance — it can become a case draft only through
  the same human-reviewed steps as a person's feedback, and it can never
  become an asset directly.

  The model is asked for JSON and read leniently: a reflection that answered
  in prose is not an error, it is zero opportunities with the prose kept for
  the operator.

  Citation syntax is not provenance. A historical mined record named an entry
  absent from its source session. Mining now checks every citation against the
  bounded evidence actually shown, and recording requires the host's source
  entries before it writes anything. A fallback anchor is labelled as such;
  it is not a citation supplied by the model. Membership establishes where to
  inspect a claim, not whether that claim is true or experimentally verifiable.
  """

  alias Lemieux.Agent.Session, as: AgentSession
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Feedback
  alias Lemieux.Feedback.Store, as: FeedbackStore
  alias Lemieux.Reflection

  @classes ~w(mechanical environmental human_review subjective_judge unknown)
  @types ~w(bug missed_requirement product_requirement style_preference taste unknown)

  # A reasoning model spends its output budget thinking before it writes the JSON
  # array, and a budget that only fits the reasoning leaves a truncated answer that
  # parses to zero opportunities — mining that silently finds nothing. Found live:
  # one model at default effort spent all 4096 of the old default on reasoning and
  # returned no answer on ten real sessions, which yield real opportunities at 16k.
  # Generous because the failure is silent.
  @default_max_tokens 16_000

  @typedoc "One mined opportunity, JSON-shaped."
  @type opportunity :: %{required(String.t()) => term()}

  @doc "Instructions asking for a JSON list of opportunities over the evidence."
  @spec instructions(evidence :: map()) :: String.t()
  def instructions(evidence) when is_map(evidence) do
    Reflection.instructions(evidence) <>
      """

      OUTPUT CONTRACT: answer with a JSON array only, no prose before or after.
      Each element is an object with exactly these keys:
        "title": short string;
        "claim": one falsifiable sentence about harness behavior, not model mood;
        "type": one of #{Enum.join(@types, ", ")};
        "verifiability": one of #{Enum.join(@classes, ", ")} — mechanical means a
          command can decide it, environmental means a sandbox observation can;
        "evidence_entry_ids": list of entry ids from the evidence that support it;
        "proposed_case": null, or {"prompt": string, "verifier": [argv strings],
          "allowed_changed_paths": [strings]} describing a minimal reproduction;
        "confidence": number between 0 and 1.
      Return [] when the evidence does not justify any opportunity.
      """
  end

  @doc """
  Runs one bounded, tool-less reflection session over `entries` and returns
  the parsed opportunities with the raw answer.

  Options: `:provider`, `:model` (required), `:sessions_dir`, `:timeout_ms`,
  `:max_evidence_bytes`, `:max_tokens`, `:reasoning_effort`, `:extensions`,
  `:max_cost_usd` (metered; otherwise a two-request quota bound).
  """
  @spec mine(entries :: [Entry.t()], opts :: keyword()) ::
          {:ok, [opportunity()], map()} | {:error, term()}
  def mine(entries, opts) when is_list(entries) and is_list(opts) do
    with {:ok, provider} <- fetch(opts, :provider),
         {:ok, model} <- fetch(opts, :model) do
      evidence =
        Reflection.gather(
          entries,
          Keyword.take(opts, [:max_evidence_bytes, :extensions, :host_evidence])
        )

      cwd = Keyword.get_lazy(opts, :cwd, fn -> scratch() end)

      session_options =
        [
          system: instructions(evidence),
          tools: [],
          max_turns: 2,
          reasoning_effort: Keyword.get(opts, :reasoning_effort),
          params: [
            max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
            temperature: 0.0
          ]
        ] ++ budget(opts)

      agent_options =
        [provider: provider, model: model, session_options: session_options] ++
          Keyword.take(opts, [:sessions_dir, :timeout_ms])

      input = %{
        prompt: "List the opportunities the evidence supports, as JSON.",
        cwd: cwd,
        timeout_ms: Keyword.get(opts, :timeout_ms, :timer.minutes(5))
      }

      case AgentSession.run(input, agent_options) do
        {:ok, observation} ->
          mined(observation, evidence)

        {:error, _reason, observation} when is_map(observation) ->
          mined(observation, evidence)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp mined(observation, evidence) do
    opportunities = parse(observation["answer"])
    known = MapSet.new(evidence["events"], & &1["id"])

    with :ok <- validate_ids(citations(opportunities), known),
         do: {:ok, opportunities, observation}
  end

  @doc "Parses a model answer leniently into validated opportunities."
  @spec parse(answer :: String.t() | nil) :: [opportunity()]
  def parse(answer) when is_binary(answer) do
    with [json | _] <- Regex.run(~r/\[.*\]/s, answer),
         {:ok, list} when is_list(list) <- JSON.decode(json) do
      list |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)
    else
      _other -> []
    end
  end

  def parse(_answer), do: []

  @doc """
  Records opportunities as feedback with a model actor and reflection
  provenance. `provenance` must carry `tenant_id`, `project_id` and
  `session_id`; each record anchors on the opportunity's first evidence entry
  or on `:fallback_entry_id`. A nonempty batch requires `:source_entries`,
  resolved by the host under that session's authority. All citations and any
  fallback must belong to those entries. Validation happens before the first
  append; a store failure can still leave a partially persisted batch.

  Records retain the canonical source-entry digest and distinguish a cited
  anchor from a fallback. Existing historical records are never rewritten.
  Returns the stored feedback ids. Invalid mining answers remain in their
  original reflection transcript; refusal makes no repair or provider request.
  """
  @spec record(
          opportunities :: [opportunity()],
          provenance :: map(),
          store :: FeedbackStore.t(),
          opts :: keyword()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def record(opportunities, provenance, store, opts \\ [])

  def record([], provenance, _store, opts) when is_map(provenance) and is_list(opts),
    do: {:ok, []}

  def record(opportunities, provenance, store, opts)
      when is_list(opportunities) and is_map(provenance) and is_list(opts) do
    with {:ok, entries} <- source_entries(opts),
         known = MapSet.new(entries, & &1.id),
         fallback = Enum.any?(opportunities, &(&1["evidence_entry_ids"] == [])),
         :ok <- validate_ids(citations(opportunities), known),
         :ok <- validate_ids(if(fallback, do: [opts[:fallback_entry_id]], else: []), known) do
      validation = %{
        "policy" => "transcript_entry_membership/v1",
        "source_entry_count" => length(entries),
        "source_entries_sha256" => Contract.sha256(Enum.map(entries, &[Entry.encode!(&1), ?\n]))
      }

      model = Keyword.get(opts, :model, "unknown")
      opts = Keyword.put(opts, :evidence_validation, validation)
      append_opportunities(opportunities, provenance, store, model, opts)
    end
  end

  defp append_opportunities(opportunities, provenance, store, model, opts) do
    Enum.reduce_while(opportunities, {:ok, []}, fn opportunity, {:ok, ids} ->
      case record_one(opportunity, provenance, store, model, opts) do
        {:ok, id} -> {:cont, {:ok, ids ++ [id]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp source_entries(opts) do
    case Keyword.fetch(opts, :source_entries) do
      {:ok, [_ | _] = entries} ->
        if Enum.all?(entries, &match?(%Entry{id: id} when is_binary(id) and id != "", &1)) and
             length(entries) == MapSet.size(MapSet.new(entries, & &1.id)),
           do: {:ok, entries},
           else: {:error, :invalid_source_entries}

      {:ok, _invalid} ->
        {:error, :invalid_source_entries}

      :error ->
        {:error, :source_entries_required}
    end
  end

  defp citations(opportunities), do: Enum.flat_map(opportunities, & &1["evidence_entry_ids"])

  defp validate_ids(ids, known) do
    case ids |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.uniq() |> Enum.sort() do
      [] -> :ok
      invalid -> {:error, {:invalid_evidence_entry_ids, invalid}}
    end
  end

  defp record_one(opportunity, provenance, store, model, opts) do
    with {:ok, feedback} <- build_feedback(opportunity, provenance, model, opts),
         :ok <- FeedbackStore.append(store, feedback) do
      {:ok, feedback.id}
    end
  end

  defp build_feedback(opportunity, provenance, model, opts) do
    anchor =
      List.first(opportunity["evidence_entry_ids"]) || Keyword.get(opts, :fallback_entry_id)

    record_provenance =
      provenance
      |> Map.merge(%{"host" => "reflection", "entry_id" => anchor})
      |> Map.put("opportunity", Map.drop(opportunity, ["claim", "title"]))
      |> Map.put(
        "evidence_validation",
        Map.put(
          Keyword.fetch!(opts, :evidence_validation),
          "anchor_kind",
          if(opportunity["evidence_entry_ids"] == [], do: "fallback", else: "citation")
        )
      )

    case Feedback.new(text(opportunity), record_provenance,
           type: feedback_type(opportunity["type"]),
           verifiability: %{"class" => opportunity["verifiability"], "source" => "model_claim"},
           actor: %{"type" => "model", "id" => model},
           scope: Keyword.get(opts, :scope, :project)
         ) do
      {:ok, feedback} -> {:ok, feedback}
      {:error, reason} -> {:error, {:invalid_opportunity, opportunity["title"], reason}}
    end
  end

  defp text(opportunity), do: "#{opportunity["title"]}: #{opportunity["claim"]}"

  # Written out rather than `String.to_existing_atom/1`, which looked safe and was
  # not: the atom it needs only exists once `Lemieux.Feedback` has been *loaded*,
  # and this runs while building that call's arguments — so a live reflection naming
  # a `product_requirement` in a fresh VM crashed the whole mining run. The strings
  # are already validated against `@types` by `normalize/1`.
  defp feedback_type("bug"), do: :bug
  defp feedback_type("missed_requirement"), do: :missed_requirement
  defp feedback_type("product_requirement"), do: :product_requirement
  defp feedback_type("style_preference"), do: :style_preference
  defp feedback_type("taste"), do: :taste
  defp feedback_type(_unknown), do: :unknown

  defp normalize(%{"title" => title, "claim" => claim} = raw)
       when is_binary(title) and is_binary(claim) do
    %{
      "title" => title,
      "claim" => claim,
      "type" => enum(raw["type"], @types, "unknown"),
      "verifiability" => enum(raw["verifiability"], @classes, "unknown"),
      "evidence_entry_ids" =>
        raw["evidence_entry_ids"] |> List.wrap() |> Enum.filter(&is_binary/1),
      "proposed_case" => proposed_case(raw["proposed_case"]),
      "confidence" => confidence(raw["confidence"])
    }
  end

  # A model that wrote the claim and skipped the label found something. The label is
  # how a person recognises it in a ledger, not part of the finding, and a live
  # reflection lost three whole opportunities to its absence — the same defect as a
  # child envelope discarded for its shape.
  defp normalize(%{"claim" => claim} = raw) when is_binary(claim) and claim != "",
    do: raw |> Map.put("title", summary(claim)) |> normalize()

  defp normalize(_raw), do: nil

  defp summary(claim) do
    claim
    |> String.split(~r/(?<=\.)\s+/, parts: 2)
    |> List.first()
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp enum(value, allowed, default), do: if(value in allowed, do: value, else: default)

  defp proposed_case(%{"prompt" => prompt, "verifier" => verifier} = raw)
       when is_binary(prompt) and is_list(verifier) and verifier != [] do
    if Enum.all?(verifier, &is_binary/1),
      do: %{
        "prompt" => prompt,
        "verifier" => verifier,
        "allowed_changed_paths" =>
          raw["allowed_changed_paths"] |> List.wrap() |> Enum.filter(&is_binary/1)
      },
      else: nil
  end

  defp proposed_case(_raw), do: nil

  defp confidence(value) when is_number(value) and value >= 0 and value <= 1, do: value * 1.0
  defp confidence(_value), do: nil

  defp budget(opts) do
    case Keyword.get(opts, :max_cost_usd) do
      nil -> [max_requests: 2]
      cap -> [max_cost_usd: cap]
    end
  end

  defp scratch do
    dir = Path.join(System.tmp_dir!(), "lemieux-reflection-" <> Lemieux.ID.generate())
    File.mkdir_p!(dir)
    dir
  end

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _missing -> {:error, {key, :required}}
    end
  end
end
