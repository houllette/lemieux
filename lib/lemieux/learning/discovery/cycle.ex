defmodule Lemieux.Learning.Discovery.Cycle do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  One generation of routine self-improvement: search, confirm, recommend.

  A campaign on its own is an experiment somebody remembers to run. What
  makes self-improvement routine is a unit of work small enough to schedule
  and honest enough to leave unattended. A cycle is that unit:

    1. the seed is the configured base profile with the overlay file
       (`:overlay_path`, `.lmx/harness.json` by default) applied whole, so
       every generation starts from what the last exported overlay changed,
       not from a fixed prompt;
    2. a bounded discovery campaign runs;
    3. the frontier member with the best primary objective (fewest changed
       bytes on a tie) is confirmed on the configured confirmation models,
       on cases the search never saw;
    4. the cycle writes its verdict to a ledger and recommends `export`,
       `hold`, `retarget-proposer` or `grow-corpus`, and does nothing else.

  The seed is the harness a host runs only when that harness is the same
  profile plus the same file, and `lmx`'s is not: `lmx` starts from its own
  system prompt, adds the person's `~/.lmx/harness.json`, and takes only a
  repository overlay's system-prompt text
  (`Lemieux.Extensions.Workspace.Discovery`), where a cycle applies the one
  file whole, tool descriptions included. A cycle's verdict is about the
  configured profile and that file. This description once called the seed
  "the harness the host currently runs", which invited reading a verdict as
  one on `lmx` itself.

  The recommendation is the whole of the automation's authority. A cycle
  never writes the overlay: `lmx harness export` does, and a person's review
  of that file in version control is the activation. What lets a cycle run
  on a schedule with nobody watching is the allowance: a cap on what the
  ledger may show spent over a window, checked before the campaign starts
  against the cycle's own worst case. A cycle that could take the ledger
  past the line is refused rather than clamped, because a clamped campaign
  is a different experiment from the one that was configured and its
  frontier would not mean what the last one meant. A confirmation that
  passes on one configured model and fails on another is a `hold`, because
  the harness belongs to whoever runs it, on whatever model they choose.
  When the proposer's calibration is worse than predicting no change, the
  recommendation is to spend the next cycle on the proposer (a meta
  campaign) rather than on the harness, which is the case the literature
  says is the common one. When the seed already passes every development
  case on every model, no edit can rank above it and the proposer's
  calibration is measured on nothing but risk; the second live cycle read
  that as a bad proposer when the corpus had simply run out of failures, so
  a saturated seed recommends growing the corpus before either.
  """

  alias Lemieux.Contract
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Confirm
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Overlay

  @ledger "cycles.jsonl"

  @typedoc """
  A cycle configuration: everything `Lemieux.Learning.Discovery.Campaign`
  accepts (the `:output_dir` becomes the cycle root), plus `:overlay_path`
  (the overlay file to seed from; default `.lmx/harness.json`, absent is
  fine), `:confirmation` (a keyword list of `Confirm.run/3` options, plus
  `:models` — a list of model strings or maps as the evaluator accepts; the
  candidate is confirmed on each), `:brier_hold` (default 0.25: a mean
  Brier above this recommends a meta cycle), and `:allowance` (optional: a
  map with any of `"maximum_cost_usd"`, `"maximum_tokens"` and
  `"window_days"`; the cycle is refused when the ledger's spend inside the
  window plus this cycle's configured maximum would exceed a limit. Tokens
  count the campaign only; confirmations are bounded in dollars, not
  tokens).
  """
  @type config :: keyword()

  @typedoc "Dollars and tokens, as summed from the ledger."
  @type spend :: %{String.t() => number()}

  @doc "Runs one cycle and returns its ledger entry."
  @spec run(config :: config()) :: {:ok, map()} | {:error, term()} | {:error, term(), term()}
  def run(config) when is_list(config) do
    with {:ok, root} <- fetch(config, :output_dir),
         {:ok, base} <- fetch(config, :seed_profile),
         {:ok, overlay} <-
           Overlay.read(Keyword.get(config, :overlay_path, Path.join(".lmx", Overlay.filename()))),
         {:ok, seed} <- seeded(base, overlay),
         {:ok, admission} <- admission(config, root) do
      cycle_id = "cycle_" <> Lemieux.ID.generate()
      dir = Path.join(root, cycle_id)

      campaign_config =
        config
        |> Keyword.put(:seed_profile, seed)
        |> Keyword.put(:output_dir, Path.join(dir, "campaign"))

      started = System.monotonic_time(:millisecond)

      case Campaign.run(campaign_config) do
        {:ok, result} ->
          entry =
            config
            |> decide(campaign_config, cycle_id, dir, overlay, seed, result, started)
            |> Map.put("allowance", admission)

          persist(root, dir, entry)
          {:ok, entry}

        {:error, reason, state} ->
          entry =
            cycle_id
            |> failed_entry(dir, overlay, seed, reason, started, state)
            |> Map.put("allowance", admission)

          persist(root, dir, entry)
          {:error, reason, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "The ledger under a cycle root, oldest first; absent is empty."
  @spec ledger(root :: Path.t()) :: [map()]
  def ledger(root) do
    case File.read(Path.join(root, @ledger)) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, _reason} -> []
    end
  end

  @doc """
  Dollars and tokens the ledger shows spent inside the last `window_days`
  (`nil` for all time). An entry written before spend was recorded counts
  its campaign tokens and no dollars.
  """
  @spec spend(entries :: [map()], window_days :: number() | nil) :: spend()
  def spend(entries, window_days) when is_list(entries) do
    entries
    |> Enum.filter(&within_window?(&1, window_days))
    |> Enum.reduce(%{"cost_usd" => 0.0, "tokens" => 0}, fn entry, acc ->
      spent = entry["spend"] || %{"tokens" => get_in(entry, ["campaign", "tokens"])}

      %{
        "cost_usd" => acc["cost_usd"] + (spent["cost_usd"] || 0.0) * 1.0,
        "tokens" => acc["tokens"] + (spent["tokens"] || 0)
      }
    end)
  end

  @doc """
  Whether the allowance admits one more cycle given the ledger under `root`.
  Without an `:allowance` every cycle is admitted. The detail names the
  window, what was spent inside it, what this cycle could spend at most,
  the limits, and on refusal which of them would be exceeded.
  """
  @spec admission(config :: config(), root :: Path.t()) ::
          {:ok, map() | nil} | {:error, {:allowance_exhausted, map()}}
  def admission(config, root) do
    case Keyword.get(config, :allowance) do
      nil ->
        {:ok, nil}

      allowance ->
        allowance = Contract.json(allowance)
        window = allowance["window_days"]
        spent = spend(ledger(root), window)
        planned = planned(config)

        exceeded =
          Enum.filter(["cost_usd", "tokens"], fn key ->
            limit = allowance["maximum_" <> key]
            is_number(limit) and spent[key] + planned[key] > limit
          end)

        detail = %{
          "window_days" => window,
          "spent_before" => spent,
          "planned" => planned,
          "limits" => Map.take(allowance, ["maximum_cost_usd", "maximum_tokens"])
        }

        if exceeded == [],
          do: {:ok, detail},
          else: {:error, {:allowance_exhausted, Map.put(detail, "exceeded", exceeded)}}
    end
  end

  @doc """
  A summary of the ledger for a configuration: how many cycles ran, the
  last one's verdict, the spend inside the allowance window and all time,
  and whether the next cycle would be admitted. Runs nothing.
  """
  @spec status(config :: config()) :: map()
  def status(config) when is_list(config) do
    root = Keyword.fetch!(config, :output_dir)
    entries = ledger(root)
    window = config |> Keyword.get(:allowance) |> Contract.json() |> window_days()
    last = List.last(entries)

    {admitted, refusal} =
      case admission(config, root) do
        {:ok, _detail} -> {true, nil}
        {:error, {:allowance_exhausted, detail}} -> {false, detail}
      end

    %{
      "root" => root,
      "cycles" => length(entries),
      "last" => last && Map.take(last, ["cycle_id", "at", "recommendation", "next", "selected"]),
      "recommendations" => entries |> Enum.map(& &1["recommendation"]) |> Enum.frequencies(),
      "window_days" => window,
      "spend" => spend(entries, window),
      "spend_all_time" => spend(entries, nil),
      "admitted" => admitted,
      "refusal" => refusal
    }
  end

  defp window_days(%{"window_days" => days}) when is_number(days), do: days
  defp window_days(_allowance), do: nil

  defp within_window?(_entry, nil), do: true

  defp within_window?(entry, days) do
    case DateTime.from_iso8601(entry["at"] || "") do
      {:ok, at, _offset} -> DateTime.diff(DateTime.utc_now(), at, :second) <= days * 86_400
      _invalid -> true
    end
  end

  # The worst case this cycle is configured to spend: the campaign's own caps
  # plus the confirmation cost cap once per confirmation model. There is no
  # token cap on a confirmation, so tokens are the campaign's alone.
  defp planned(config) do
    budget = config |> Keyword.get(:budget, %{}) |> Contract.json()
    confirmation = Keyword.get(config, :confirmation, [])
    models = Keyword.get(confirmation, :models, [nil])
    per_model = Keyword.get(confirmation, :max_cost_usd, 0.0) || 0.0

    %{
      "cost_usd" => (budget["maximum_cost_usd"] || 0.0) * 1.0 + per_model * length(models),
      "tokens" => budget["maximum_tokens"] || 0
    }
  end

  @doc "The seed a cycle starts from: the base profile with the overlay applied whole."
  @spec seeded(base :: map(), overlay :: Overlay.t() | nil) :: {:ok, map()} | {:error, term()}
  def seeded(base, overlay) when is_map(base) do
    options = base["options"]

    seed =
      base
      |> put_in(["options", "system"], Overlay.apply_system(overlay, options["system"]))
      |> put_in(
        ["options", "tool_descriptions"],
        Map.merge(
          Map.get(options, "tool_descriptions", %{}),
          (overlay && overlay.tool_descriptions) || %{}
        )
      )

    with :ok <- Profile.validate(seed), do: {:ok, seed}
  end

  @doc "Chooses the candidate a cycle confirms: best primary objective, then fewest changed bytes."
  @spec selection(plan :: Plan.t(), result :: map()) :: Candidate.t() | nil
  def selection(plan, result) do
    policy = Policy.read(plan)
    objective = policy["success_objective"]
    scores = Map.new(result.frontier.members, &{&1["candidate_id"], &1["scores"]})

    result.candidates
    |> Enum.filter(&(Map.has_key?(scores, &1.id) and &1.mutation_kind != "seed"))
    |> Enum.sort_by(&{-(scores[&1.id][objective] || 0.0), &1.content.size_bytes, &1.id})
    |> List.first()
  end

  defp decide(config, campaign_config, cycle_id, dir, overlay, seed, result, started) do
    {:ok, plan} = Plan.decode(File.read!(Path.join(dir, "campaign/plan.json")))

    selected = selection(plan, result)
    brier = get_in(result, [:calibration, "aggregate", "mean_brier"])
    confirmations = if selected, do: confirm_all(campaign_config, config, selected), else: []
    saturated = saturated?(plan, result)

    recommendation =
      recommend(
        selected,
        confirmations,
        brier,
        Keyword.get(config, :brier_hold, 0.25),
        saturated
      )

    %{
      "schema_version" => 1,
      "cycle_id" => cycle_id,
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "duration_ms" => System.monotonic_time(:millisecond) - started,
      "seed" => %{
        "sha256" => Contract.sha256(Contract.encode!(seed)),
        "overlay_sha256" => overlay && overlay.sha256,
        "overlay_qualification" => overlay && overlay.qualification
      },
      "campaign" => %{
        "dir" => Path.join(dir, "campaign"),
        "plan_id" => plan.id,
        "plan_sha256" => plan.sha256,
        "status" => Atom.to_string(result.state.status),
        "candidates" => length(result.candidates),
        "evaluations" => length(result.evaluations),
        "tokens" => result.state.budget["tokens"],
        "frontier" => Enum.map(result.frontier.members, & &1["candidate_id"]),
        "calibration" => Map.take(result.calibration || %{}, ["status", "aggregate"]),
        "acceptance" => result.acceptance
      },
      "spend" => spent(result.state.budget, confirmations),
      "saturated" => saturated,
      "selected" => selected && selected.id,
      "confirmations" => confirmations,
      "recommendation" => recommendation,
      "next" => next_step(recommendation, dir, selected)
    }
  end

  defp spent(budget, confirmations) do
    confirmed =
      confirmations
      |> Enum.map(&get_in(&1, ["resources", "observed_cost_usd"]))
      |> Enum.filter(&is_number/1)
      |> Enum.sum()

    %{
      "cost_usd" => (budget["cost_usd"] || 0.0) * 1.0 + confirmed,
      "tokens" => budget["tokens"] || 0
    }
  end

  defp confirm_all(campaign_config, config, selected) do
    confirmation = Keyword.get(config, :confirmation, [])
    models = Keyword.get(confirmation, :models, [nil])
    opts = Keyword.drop(confirmation, [:models])

    Enum.map(models, fn model ->
      run_opts = if model, do: model_opts(model, opts), else: opts

      case Confirm.run(campaign_config, selected.id, run_opts) do
        {:ok, result} ->
          %{
            "model" => model_name(model),
            "verdict" => result["verdict"],
            "reason" => result["reason"],
            "pairs" => result["pairs"],
            "resources" => result["resources"]
          }

        {:error, reason} ->
          %{"model" => model_name(model), "verdict" => "error", "reason" => inspect(reason)}
      end
    end)
  end

  # Each confirmation model gets its own single-use directory: a second run of
  # the same candidate in the same directory is refused by design.
  defp model_opts(model, opts) when is_binary(model),
    do: Keyword.merge(opts, model: model, suffix: model)

  defp model_opts(%{"model" => model} = entry, opts) do
    opts
    |> Keyword.merge(model: model, suffix: model)
    |> maybe(:usage_mode, entry["usage_mode"])
    |> maybe(:max_cost_per_attempt_usd, entry["max_cost_usd"])
    |> maybe(:max_requests_per_attempt, entry["max_requests"])
  end

  defp maybe(opts, _key, nil), do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, value)

  defp model_name(nil), do: "search_model"
  defp model_name(model) when is_binary(model), do: model
  defp model_name(%{"model" => model}), do: model

  @doc "Whether the seed passed every development case; such a corpus cannot rank an edit."
  @spec saturated?(plan :: Plan.t(), result :: map()) :: boolean()
  def saturated?(plan, result) do
    policy = Policy.read(plan)

    case Enum.find(result.candidates, &(&1.mutation_kind == "seed")) do
      nil ->
        false

      seed ->
        development =
          Enum.filter(
            result.evaluations,
            &(&1.candidate_id == seed.id and Policy.development?(&1))
          )

        development != [] and Enum.all?(development, &Policy.success?(&1, policy))
    end
  end

  @doc """
  The cycle's recommendation from its confirmations, calibration, and whether
  the seed saturated the corpus.
  """
  @spec recommend(
          selected :: Candidate.t() | nil,
          confirmations :: [map()],
          brier :: number() | nil,
          hold :: number(),
          saturated :: boolean()
        ) :: String.t()
  def recommend(selected, confirmations, brier, hold, saturated \\ false)

  def recommend(nil, _confirmations, _brier, _hold, true), do: "grow-corpus"

  def recommend(nil, _confirmations, brier, hold, false),
    do: if(is_number(brier) and brier > hold, do: "retarget-proposer", else: "hold")

  def recommend(_selected, confirmations, brier, hold, saturated) do
    verdicts = Enum.map(confirmations, & &1["verdict"])

    cond do
      confirmations != [] and Enum.all?(verdicts, &(&1 == "pass")) -> "export"
      Enum.any?(verdicts, &(&1 in ["safety_failure", "critical_regression", "fail"])) -> "hold"
      saturated -> "grow-corpus"
      is_number(brier) and brier > hold -> "retarget-proposer"
      true -> "hold"
    end
  end

  defp next_step("export", dir, selected),
    do: "lmx harness export #{Path.join(dir, "campaign")} #{selected.id}"

  defp next_step("grow-corpus", _dir, _selected),
    do:
      "the seed passes every development case on every model, so nothing here can rank an edit: add cases (lmx feedback --mine, lmx corpus promote) before the next cycle"

  defp next_step("retarget-proposer", _dir, _selected),
    do:
      "the proposer's calibration is worse than predicting no change: run a meta campaign before the next cycle"

  defp next_step("hold", _dir, nil),
    do: "no eligible frontier member; grow the corpus or widen the budget"

  defp next_step("hold", dir, selected),
    do:
      "keep sampling: mix lemieux.discovery.confirm on #{selected.id} with more holdout clusters, or hold (#{Path.join(dir, "campaign")})"

  defp failed_entry(cycle_id, dir, overlay, seed, reason, started, %State{} = state) do
    budget = state.budget

    %{
      "schema_version" => 1,
      "cycle_id" => cycle_id,
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "duration_ms" => System.monotonic_time(:millisecond) - started,
      "seed" => %{
        "sha256" => Contract.sha256(Contract.encode!(seed)),
        "overlay_sha256" => overlay && overlay.sha256
      },
      "campaign" => %{
        "dir" => Path.join(dir, "campaign"),
        "status" => "failed",
        "tokens" => budget["tokens"],
        "error" => Contract.json(reason)
      },
      "spend" => spent(budget, []),
      "selected" => nil,
      "confirmations" => [],
      "recommendation" => "hold",
      "next" => "the campaign failed; inspect its archive before the next cycle"
    }
  end

  defp persist(root, dir, entry) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cycle.json"), JSON.encode!(entry))
    File.write!(Path.join(root, @ledger), JSON.encode!(entry) <> "\n", [:append])
  end

  defp fetch(config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _missing -> {:error, {key, :required}}
    end
  end
end
