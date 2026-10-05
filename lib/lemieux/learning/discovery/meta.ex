defmodule Lemieux.Learning.Discovery.Meta do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  The recursive step: a discovery campaign whose candidates are proposer
  profiles and whose cases are inner discovery campaigns.

  Hyperagents and STOP make the procedure that proposes improvements itself
  editable and archived. Here that needs no new machinery: the first-party
  proposer is an extension with a profile, so its profile is a valid
  candidate document, `Lemieux.Learning.Proposer` can propose edits to it,
  and the outer plan is an ordinary `Lemieux.Learning.Discovery.Plan` whose
  `target_interface` says so. What differs is the evaluator. One outer
  "case" is one inner campaign run with the candidate proposer profile, and
  its objectives are the things the literature says a proposer is for:

    * `frontier_yield` — the share of the inner proposer's own proposals that
      ended on the inner frontier (maximize);
    * `brier` — the inner proposer's prediction calibration from
      `Lemieux.Learning.Discovery.Calibration` (minimize). An inner run with no
      calibrated candidate scores the worst value, 1.0: a proposer that stops
      predicting is not rewarded for it, which is the rule the calibration
      module already applies per candidate;
    * `proposer_tokens` — what the inner proposer spent; measured for every
      evaluation and recorded in its observations, available as an objective
      but not one by default.

  Everything the outer loop learns is bounded by the same gates as any other
  candidate: surface validation on the proposer profile, the critic, the
  frontier's hard constraints, and the confirmation lane in `confirm/3`,
  which judges a frontier proposer profile on the validation inner campaigns
  the search planned but never ran. The outer proposer never sees an inner
  holdout because inner campaigns have none; every inner corpus is exposed
  development material.
  """

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Confirm
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Shadow
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  # Token spend is measured and reported but is not a frontier objective by
  # default: the first live meta campaign kept a proposer that was worse on yield
  # and calibration because it spent one percent fewer tokens, and a frontier that
  # cannot say "this proposer got worse" is not doing its one job. A plan may add
  # it back through `:objectives`.
  @objectives [
    %{"name" => "frontier_yield", "direction" => "maximize"},
    %{"name" => "brier", "direction" => "minimize"}
  ]
  # The smallest paired difference the confirmation lane calls an effect, per
  # objective in that objective's own units. One inner campaign per
  # validation template is a sample of one; below these a difference is the
  # inner search's own noise, not the proposer edit.
  @minimum_effect %{"frontier_yield" => 0.1, "brier" => 0.05}
  # A function, not an attribute: computing the digest at compile time would
  # make this module recompile whenever the contract module changes.
  defp trusted_local,
    do: %{"id" => "trusted-local", "sha256" => Contract.sha256("trusted-local")}

  @typedoc """
  A trusted meta-campaign configuration. Required: `:id`, `:output_dir`,
  `:provider`, `:seed_evolver_profile` (the inner proposer profile to
  improve), `:inner` (a keyword list of inner campaign templates keyed by
  case id; each template is an ordinary `Lemieux.Learning.Discovery.Campaign`
  configuration without `:id`, `:output_dir`, `:evolver_profile`,
  `:provider` or `:allow_live`), `:validation_inner` (the template names held
  as validation cases; at least one), and `:budget`. Optional:
  `:evolver_profile` (the outer proposer; default the seed), `:search`,
  `:critic_profile`, `:allow_live`, `:sessions_dir`, `:timeout_ms`.
  """
  @type config :: keyword()

  @doc "Freezes the outer plan whose seed is the inner proposer profile."
  @spec plan(config :: config()) :: {:ok, Plan.t(), binary()} | {:error, term()}
  def plan(config) when is_list(config) do
    with {:ok, id} <- fetch(config, :id),
         {:ok, seed} <- fetch(config, :seed_evolver_profile),
         :ok <- Profile.validate(seed),
         {:ok, inner} <- fetch(config, :inner),
         {:ok, budget} <- fetch(config, :budget),
         {:ok, dev, val} <- splits(inner, Keyword.get(config, :validation_inner, [])) do
      outer = Keyword.get(config, :evolver_profile, seed)
      seed_bytes = Contract.encode!(seed)
      scope = %{"id" => Keyword.get(config, :scope, "local/" <> id)}

      attrs = %{
        "id" => id,
        "scope" => scope,
        "target_interface" => %{"id" => "lemieux.proposer-profile/v1"},
        "mutation_surface" =>
          config
          |> Keyword.get(:mutation_surface, ["options.system"])
          |> Enum.map(&%{"path" => &1}),
        "seeds" => [
          %{"id" => "seed", "content_sha256" => Contract.sha256(seed_bytes), "scope" => scope}
        ],
        "proposer" => Proposer.identity(outer),
        "base_model" => %{"id" => seed["model"], "sha256" => Contract.sha256(seed["model"])},
        "development_case_ids" => dev,
        "validation_case_ids" => val,
        "objectives" => Keyword.get(config, :objectives, @objectives),
        "hard_constraints" => [
          %{"id" => "trusted-local", "kind" => "mechanical", "sandbox" => "not_applicable"},
          %{
            "id" => "max-content-bytes",
            "kind" => "max_content_bytes",
            "value" => Keyword.get(config, :max_content_bytes, 32_000)
          },
          %{
            "id" => "forbidden-references",
            "kind" => "forbidden_references",
            # A proposer profile legitimately says "never mention graders", so
            # the inner corpus's grader names cannot be the meta-level filter.
            # What an outer edit must never do is point the inner proposer at
            # held-out material.
            "patterns" => ["holdout", "solutions/"]
          }
        ],
        "interface_validator" => Surface.validator(),
        "budget" => budget,
        "extensions" => %{
          "search" => Map.merge(%{"success_threshold" => 0.5}, Keyword.get(config, :search, %{})),
          "meta" => %{"level" => "meta", "inner_cases" => dev ++ val}
        }
      }

      with {:ok, plan} <- Plan.new(attrs), do: {:ok, plan, seed_bytes}
    end
  end

  @doc "Runs the meta campaign and persists the outer archive under `:output_dir`."
  @spec run(config :: config()) ::
          {:ok, Shadow.result()} | {:error, term()} | {:error, term(), State.t()}
  def run(config) when is_list(config) do
    with {:ok, output_dir} <- fetch(config, :output_dir),
         {:ok, provider} <- fetch(config, :provider),
         :ok <- live_allowed(config, provider),
         {:ok, plan, seed_bytes} <- plan(config),
         :ok <- Campaign.preamble(output_dir, plan, seed_bytes) do
      search(config, plan, provider, output_dir,
        artifacts: %{Contract.sha256(seed_bytes) => seed_bytes}
      )
    end
  end

  @doc """
  Resumes an interrupted meta campaign from the archive under `:output_dir`.

  An outer campaign is expensive in a way an ordinary one is not: every outer
  evaluation is a whole inner campaign, and every inner campaign is a search
  of its own. Restarting one from scratch discards inner campaigns that
  already ran to a frontier — work that was paid for and is sitting complete
  in the archive. So resuming happens at two levels:

    * the outer search resumes exactly as `Lemieux.Learning.Discovery.Campaign.resume/1`
      does, from the persisted candidates, evaluations and state; and
    * an inner campaign directory that already holds a finished campaign is
      **read**, not rerun, and one that was interrupted part way is resumed
      rather than restarted. A candidate whose evaluation was lost because the
      process died between its second and third inner campaign therefore pays
      only for the third.

  The persisted plan is authoritative: the configuration must still name the
  same outer proposer and the same inner campaign templates. A configuration
  that renamed or re-split them is a different experiment, and continuing it
  under the old plan's identity would make the archive a lie.
  """
  @spec resume(config :: config()) ::
          {:ok, Shadow.result()} | {:error, term()} | {:error, term(), State.t()}
  def resume(config) when is_list(config) do
    with {:ok, output_dir} <- fetch(config, :output_dir),
         {:ok, provider} <- fetch(config, :provider),
         :ok <- live_allowed(config, provider),
         {:ok, seed} <- fetch(config, :seed_evolver_profile),
         {:ok, inner} <- fetch(config, :inner),
         {:ok, plan} <- Campaign.read_plan(output_dir),
         outer = Keyword.get(config, :evolver_profile, seed),
         :ok <- same_meta_campaign(plan, outer, inner),
         {:ok, archive} <- Campaign.read_archive(output_dir, plan) do
      search(config, plan, provider, output_dir, resume: archive, artifacts: archive.artifacts)
    end
  end

  # The one search loop both entry points drive, so a change to how the outer
  # proposer or evaluator is wired cannot apply to a fresh run and miss a
  # resumed one.
  defp search(config, plan, provider, output_dir, opts) do
    outer = Keyword.get(config, :evolver_profile, Keyword.fetch!(config, :seed_evolver_profile))

    proposer_context = %{
      level: "meta",
      workspace_root: Path.join(output_dir, "proposals"),
      provider: Keyword.get(config, :proposer_provider, provider),
      evolver_profile: outer,
      critic_profile: critic_profile(config, outer),
      sessions_dir: Keyword.get(config, :sessions_dir, Path.join(output_dir, "sessions")),
      timeout_ms: Keyword.get(config, :timeout_ms, :timer.minutes(10))
    }

    proposer = fn plan, state, context ->
      Proposer.propose(plan, state, Map.merge(context, proposer_context))
    end

    evaluator = fn plan, candidate, context ->
      evaluate(plan, candidate, context, config, provider, output_dir)
    end

    shadow_opts =
      [
        mode: :shadow,
        sandbox: trusted_local(),
        exposed_corpus: %{
          "id" => "inner-campaigns",
          "sha256" => Contract.sha256(inspect(Keyword.keys(Keyword.fetch!(config, :inner))))
        },
        search: true,
        policy: Keyword.get(config, :search, %{}),
        observer: Campaign.observer(output_dir)
      ] ++ opts

    plan
    |> Shadow.run(proposer, evaluator, shadow_opts)
    |> then(&Campaign.finish(output_dir, plan, &1))
  end

  # The meta level's analogue of the campaign's manifest digest: an outer plan
  # is identified by the proposer it was frozen under and the inner campaigns
  # it was frozen over.
  defp same_meta_campaign(%Plan{} = plan, outer, inner) do
    configured = inner |> Keyword.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    recorded = (get_in(plan.extensions, ["meta", "inner_cases"]) || []) |> Enum.sort()

    cond do
      plan.proposer != Proposer.identity(outer) -> {:error, :resume_evolver_profile_mismatch}
      configured != recorded -> {:error, :resume_inner_campaigns_mismatch}
      true -> :ok
    end
  end

  @doc """
  Evaluates one proposer-profile candidate by running the inner campaign for
  each selected case with that profile as the inner evolver.
  """
  @spec evaluate(
          plan :: Plan.t(),
          candidate :: Candidate.t(),
          context :: map(),
          config :: config(),
          provider :: term(),
          output_dir :: Path.t()
        ) ::
          {:ok, map()} | {:error, term()}
  def evaluate(%Plan{} = plan, %Candidate{} = candidate, context, config, provider, output_dir) do
    digest = Candidate.content_sha256(candidate)

    with {:ok, bytes} <- artifact(context.artifacts, digest),
         {:ok, evolver} <- decode(bytes) do
      inner = Keyword.fetch!(config, :inner)
      initial = {:ok, %{evaluations: [], artifacts: %{}, incomplete: []}}

      Enum.reduce_while(context.case_ids, initial, fn case_id, {:ok, acc} ->
        template = Keyword.fetch!(inner, String.to_atom(case_id))
        dir = Path.join([output_dir, "inner", safe(candidate.id), safe(case_id)])
        sessions_dir = Keyword.get(config, :sessions_dir, Path.join(output_dir, "sessions"))

        template
        |> inner_config("#{plan.id}-#{candidate.id}-#{case_id}", dir, evolver, sessions_dir,
          config: config,
          provider: provider
        )
        |> inner_campaign(dir)
        |> collect(plan, candidate, case_id, dir, acc)
      end)
    end
  end

  # Three states a directory can be in, and the reason each is treated differently
  # is money. A finished inner campaign is evidence already bought: re-running it
  # would buy the same evidence twice, and its own frontier would come back
  # different, moving the outer scores for a reason the outer search did not cause.
  # An interrupted one is resumed. Only an untouched directory starts from nothing.
  #
  # One inner campaign per (candidate, case) is what the evaluation id already
  # encodes, so reuse is consistent with it rather than a shortcut around it. A
  # directory holding only a preamble is neither finished nor resumable, and
  # `Campaign.run/1` refuses it by name rather than deleting an archive nobody
  # asked to lose.
  defp inner_campaign(config, dir) do
    cond do
      Campaign.finished?(dir) -> Campaign.read_result(dir)
      Campaign.interrupted?(dir) -> Campaign.resume(config)
      true -> Campaign.run(config)
    end
  end

  # One inner campaign configuration for either lane: the template plus what
  # the meta level decides — identity, archive location, the proposer profile
  # under test, the provider, and whether live calls are allowed.
  defp inner_config(template, id, dir, evolver, sessions_dir, config: config, provider: provider) do
    Keyword.merge(template,
      id: id,
      output_dir: dir,
      evolver_profile: evolver,
      provider: provider,
      allow_live: Keyword.get(config, :allow_live, false),
      sessions_dir: sessions_dir
    )
  end

  # Folds one inner campaign's outcome into the reduce_while accumulator: a
  # completed campaign becomes an evaluation, a campaign that failed after
  # reaching a state is recorded as incomplete, and one that could not start
  # halts the evaluation.
  defp collect({:ok, result}, plan, candidate, case_id, dir, acc) do
    case inner_evaluation(plan, candidate, case_id, result, dir) do
      {{:ok, evaluation}, artifacts} ->
        {:cont,
         {:ok,
          %{
            acc
            | evaluations: acc.evaluations ++ [evaluation],
              artifacts: Map.merge(acc.artifacts, artifacts)
          }}}

      {{:error, reason}, _artifacts} ->
        {:halt, {:error, reason}}
    end
  end

  defp collect({:error, reason, %State{}}, _plan, _candidate, case_id, _dir, acc) do
    {:cont,
     {:ok,
      %{
        acc
        | incomplete:
            acc.incomplete ++ [%{"case_id" => case_id, "error" => Contract.json(reason)}]
      }}}
  end

  defp collect({:error, reason}, _plan, _candidate, case_id, _dir, _acc),
    do: {:halt, {:error, {:inner_campaign, case_id, reason}}}

  @doc "Objective values for an inner campaign result."
  @spec objectives(result :: Shadow.result()) :: %{String.t() => float()}
  def objectives(result) when is_map(result) do
    proposals = Enum.reject(result.candidates, &(&1.mutation_kind == "seed"))
    members = MapSet.new(Enum.map(result.frontier.members, & &1["candidate_id"]))
    on_frontier = Enum.count(proposals, &MapSet.member?(members, &1.id))

    brier =
      case get_in(result, [:calibration, "aggregate", "mean_brier"]) do
        value when is_number(value) -> value * 1.0
        _none -> 1.0
      end

    tokens =
      proposals
      |> Enum.map(&(get_in(&1.extensions, ["proposer_usage", "tokens"]) || 0))
      |> Enum.sum()

    %{
      "frontier_yield" => if(proposals == [], do: 0.0, else: on_frontier / length(proposals)),
      "brier" => brier,
      "proposer_tokens" => tokens * 1.0
    }
  end

  defp inner_evaluation(plan, candidate, case_id, result, dir) do
    report = File.read!(Path.join(dir, "report.md"))

    reference =
      ArtifactReference.from_bytes("meta_report", report,
        id: "meta_report_#{candidate.id}_#{case_id}",
        media_type: "text/markdown",
        content_schema: "lemieux.campaign-report/v1",
        scope: plan.scope
      )

    gamed = gamed(result)
    proposals = Enum.reject(result.candidates, &(&1.mutation_kind == "seed"))
    inner_tokens = result.state.budget["tokens"] || 0
    measured = objectives(result)

    attrs = %{
      "id" => "eval_#{candidate.id}_#{case_id}",
      "scope" => plan.scope,
      "case_id" => case_id,
      "split" => if(case_id in plan.development_case_ids, do: "development", else: "validation"),
      "objectives" => Map.take(measured, Enum.map(plan.objectives, & &1["name"])),
      "safety" => %{
        "passed" => gamed == [],
        "failures" => Enum.map(gamed, &"inner_candidate_referenced_grader:#{&1.id}")
      },
      "completeness" => %{
        "usage" =>
          if(result.state.budget["state"] == "complete", do: "complete", else: "unknown"),
        "cost" => "not_applicable",
        "sandbox" => "not_applicable",
        "artifacts" => "complete"
      },
      "usage" => %{
        "total_tokens" => inner_tokens,
        "inner_candidates" => length(result.candidates),
        "inner_proposals" => length(proposals)
      },
      "cost" => %{"usd" => result.state.budget["cost_usd"]},
      "latency" => %{"milliseconds" => result.state.budget["time_ms"] || 0},
      "artifacts" => [ArtifactReference.to_map(reference)],
      "within_budget" => result.state.status == :completed,
      "terminal" => true,
      "observations" => %{
        "inner_status" => Atom.to_string(result.state.status),
        "proposer_tokens" => measured["proposer_tokens"],
        "inner_frontier" => Enum.map(result.frontier.members, & &1["candidate_id"]),
        "inner_calibration" => Map.take(result.calibration || %{}, ["status", "aggregate"]),
        "inner_acceptance" => result.acceptance
      }
    }

    {Evaluation.new(plan, candidate, attrs), %{reference.sha256 => report}}
  end

  # An inner candidate whose interface validation failed on a forbidden
  # reference means the proposer profile under test steered its inner
  # proposer toward held-out material: a safety failure at the outer level,
  # whatever the scores say.
  defp gamed(result) do
    Enum.filter(result.candidates, fn inner ->
      get_in(inner.interface_validation, ["detail", "error"])
      |> to_string()
      |> String.contains?("forbidden_reference")
    end)
  end

  @doc """
  Confirms one proposer-profile candidate on the validation inner campaigns
  the outer search planned but never ran, paired against the seed proposer.

  Each validation template in `:inner` named by the archive plan's
  `validation_case_ids` runs twice, once with the seed proposer profile
  (control) and once with the candidate's (variant), under
  `confirmations/<candidate_id><suffix>/<template>/{control,variant}` in the
  meta archive. Both runs are scored with `objectives/1`, the variant runs
  are checked for gamed inner candidates, and `verdict/2` decides over the
  pairs with `opts[:minimum_effect]` (default
  `%{"frontier_yield" => 0.1, "brier" => 0.05}`). Options: `:minimum_effect`,
  `:suffix` (a separate single-use directory for the same candidate).

  The frozen plan, not the configuration, says which inner campaigns are
  validation: a configuration edited after the search cannot relabel a
  development campaign the candidate was tuned on. Independence holds at the
  campaign level — the outer proposer never saw evidence from these runs —
  not necessarily at the corpus level: a validation template that shares
  cases with a development template is a weaker test. One inner campaign per
  template is a sample of one, so the result is labelled development-grade
  evidence with its n; nothing is activated.

  Writes `result.json` and `report.md` to the confirmation directory and
  returns `{:ok, result}`. Refuses an unknown candidate
  (`{:error, {:unknown_candidate, id}}`), the seed as its own variant
  (`{:error, :invalid_control}`), a live provider without `:allow_live`, and
  a directory that already exists (`{:error, {:confirmation_dir_exists, dir}}`):
  rerunning the same campaigns does not make them independent again.
  """
  @spec confirm(config :: config(), candidate_id :: String.t(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def confirm(config, candidate_id, opts \\ [])
      when is_list(config) and is_binary(candidate_id) and is_list(opts) do
    with {:ok, output_dir} <- fetch(config, :output_dir),
         {:ok, provider} <- fetch(config, :provider),
         :ok <- live_allowed(config, provider),
         {:ok, arms} <- Confirm.arms(output_dir, candidate_id),
         :ok <- distinct_arms(arms),
         {:ok, variant} <- decode(arms.variant_bytes),
         {:ok, control} <- decode(arms.control_bytes),
         {:ok, templates} <- validation_templates(config, arms.plan),
         {:ok, dir} <- Confirm.claim_directory(output_dir, candidate_id, opts) do
      lane = %{
        arms: arms,
        profiles: %{"control" => control, "variant" => variant},
        config: config,
        provider: provider,
        dir: dir,
        minimum_effect: Keyword.get(opts, :minimum_effect, @minimum_effect)
      }

      run_confirmation(lane, templates)
    end
  end

  @doc """
  Decides a meta confirmation over its paired validation campaigns.

  `pairs` are the `"pairs"` of a `confirm/3` result: each carries an
  `"improvement"` map (positive means the variant is better, in the
  objective's own units) and the `"gamed"` inner candidate ids of the variant
  run. `minimum_effect` names the objectives that are judged and the smallest
  difference that counts for each. Returns `{verdict, reason}`:

    * `"safety_failure"` when any variant run gamed its inner corpus;
    * `"fail"` when any campaign is worse by at least the minimum effect on
      any judged objective;
    * `"pass"` when no campaign is worse on any judged objective and at least
      one is better by at least the minimum effect on at least one;
    * `"inconclusive"` otherwise: identical scores, differences inside the
      minimum effect, a judged objective missing from a pair, or no pairs.
  """
  @spec verdict(pairs :: [map()], minimum_effect :: %{String.t() => number()}) ::
          {String.t(), String.t()}
  def verdict(pairs, minimum_effect) when is_list(pairs) and is_map(minimum_effect) do
    judged = minimum_effect |> Map.keys() |> Enum.sort()

    cond do
      Enum.any?(pairs, &((&1["gamed"] || []) != [])) ->
        {"safety_failure", "variant_inner_candidate_referenced_grader"}

      pairs == [] ->
        {"inconclusive", "no_validation_campaigns"}

      missing = missing_objective(pairs, judged) ->
        {"inconclusive", "objective_missing:" <> missing}

      true ->
        judge(
          for pair <- pairs, name <- judged, do: {pair["improvement"][name], minimum_effect[name]}
        )
    end
  end

  defp missing_objective(pairs, judged) do
    Enum.find_value(pairs, fn pair ->
      Enum.find(judged, &(not is_number(pair["improvement"][&1])))
    end)
  end

  # One cell per judged objective per campaign: {improvement, minimum effect}.
  # A regression anywhere outranks an improvement anywhere else, because a
  # proposer that got worse on one campaign it never saw is not confirmed.
  defp judge(cells) do
    cond do
      Enum.any?(cells, fn {value, threshold} -> value <= -threshold end) ->
        {"fail", "regressed_beyond_minimum_effect"}

      Enum.all?(cells, fn {value, _threshold} -> value >= 0 end) and
          Enum.any?(cells, fn {value, threshold} -> value >= threshold end) ->
        {"pass", "improved_beyond_minimum_effect"}

      Enum.all?(cells, fn {value, _threshold} -> value == 0 end) ->
        {"inconclusive", "identical_objectives"}

      true ->
        {"inconclusive", "within_minimum_effect"}
    end
  end

  # The seed is every confirmation's control; paired against itself it would
  # tie on every objective and read as "inconclusive" when nothing was tested.
  defp distinct_arms(%{candidate: %{id: id}, control: %{id: id}}), do: {:error, :invalid_control}
  defp distinct_arms(_arms), do: :ok

  # Templates are matched by name rather than `String.to_atom/1`: the names
  # come from the archive, and a stale archive must not mint atoms.
  defp validation_templates(config, %Plan{validation_case_ids: names}) do
    inner = Keyword.get(config, :inner, [])

    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case template_for(inner, name) do
        {:ok, template} -> {:cont, {:ok, [{name, template} | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp template_for(inner, name) do
    case Enum.find(inner, fn {key, _template} -> Atom.to_string(key) == name end) do
      {_key, template} -> {:ok, template}
      nil -> {:error, {:inner_template_missing, name}}
    end
  end

  defp run_confirmation(lane, templates) do
    started_at = DateTime.utc_now()
    started = System.monotonic_time(:millisecond)

    with {:ok, pairs} <- confirm_pairs(lane, templates) do
      {verdict, reason} = verdict(pairs, lane.minimum_effect)
      n = length(pairs)

      result = %{
        "verdict" => verdict,
        "reason" => reason,
        "plan_id" => lane.arms.plan.id,
        "plan_sha256" => lane.arms.plan.sha256,
        "arms" => %{"control" => lane.arms.control.id, "variant" => lane.arms.candidate.id},
        "minimum_effect" => lane.minimum_effect,
        "sample" => %{"validation_campaigns" => n, "grade" => "development"},
        "pairs" => pairs,
        "resources" => resources(pairs),
        "timing" => %{
          "started_at" => DateTime.to_iso8601(started_at),
          "finished_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "elapsed_ms" => System.monotonic_time(:millisecond) - started
        },
        "qualification" =>
          "development-grade confirmation evidence over n=#{n} validation inner " <>
            "campaign(s); nothing is activated"
      }

      File.write!(Path.join(lane.dir, "result.json"), JSON.encode!(result))
      File.write!(Path.join(lane.dir, "report.md"), confirmation_report(result))
      {:ok, result}
    end
  end

  defp confirm_pairs(lane, templates) do
    templates
    |> Enum.reduce_while({:ok, []}, fn {name, template}, {:ok, acc} ->
      with {:ok, control} <- arm(lane, name, template, "control"),
           {:ok, variant} <- arm(lane, name, template, "variant") do
        {:cont, {:ok, [pair(lane.arms.plan, name, control, variant) | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # An inner campaign that fails is not an arm with a low score; it is an
  # arm that was not measured, and a confirmation with one unmeasured arm is
  # no confirmation.
  defp arm(lane, name, template, arm) do
    arms = lane.arms
    dir = Path.join([lane.dir, safe(name), arm])
    id = "#{arms.plan.id}-confirm-#{arms.candidate.id}-#{name}-#{arm}"
    sessions_dir = Keyword.get(lane.config, :sessions_dir, Path.join(lane.dir, "sessions"))

    template
    |> inner_config(id, dir, Map.fetch!(lane.profiles, arm), sessions_dir,
      config: lane.config,
      provider: lane.provider
    )
    |> Campaign.run()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason, %State{}} -> {:error, {:inner_campaign, name, arm, reason}}
      {:error, reason} -> {:error, {:inner_campaign, name, arm, reason}}
    end
  end

  defp pair(%Plan{objectives: objectives}, name, control_result, variant_result) do
    names = Enum.map(objectives, & &1["name"])
    control = Map.take(objectives(control_result), names)
    variant = Map.take(objectives(variant_result), names)

    improvement =
      Map.new(objectives, fn %{"name" => objective, "direction" => direction} ->
        {objective, improvement(direction, control[objective], variant[objective])}
      end)

    %{
      "case_id" => name,
      "control" => control,
      "variant" => variant,
      "improvement" => improvement,
      "gamed" => Enum.map(gamed(variant_result), & &1.id),
      "runs" => %{
        "control" => run_summary(control_result),
        "variant" => run_summary(variant_result)
      }
    }
  end

  # Positive means the variant is better, in the objective's own units; an
  # objective either run did not measure stays unmeasured rather than zero.
  defp improvement(_direction, control, variant)
       when not is_number(control) or not is_number(variant),
       do: nil

  defp improvement("maximize", control, variant), do: variant - control
  defp improvement("minimize", control, variant), do: control - variant

  defp run_summary(result) do
    %{
      "status" => Atom.to_string(result.state.status),
      "tokens" => result.state.budget["tokens"] || 0,
      "cost_usd" => result.state.budget["cost_usd"],
      "time_ms" => result.state.budget["time_ms"] || 0,
      "inner_candidates" => length(result.candidates),
      "inner_frontier" => Enum.map(result.frontier.members, & &1["candidate_id"])
    }
  end

  defp resources(pairs) do
    runs = Enum.flat_map(pairs, &Map.values(&1["runs"]))
    costs = Enum.map(runs, & &1["cost_usd"])

    %{
      "inner_campaigns" => length(runs),
      "tokens" => runs |> Enum.map(& &1["tokens"]) |> Enum.sum(),
      "cost_usd" => if(Enum.all?(costs, &is_number/1), do: Enum.sum(costs), else: nil),
      "time_ms" => runs |> Enum.map(& &1["time_ms"]) |> Enum.sum()
    }
  end

  defp confirmation_report(result) do
    n = result["sample"]["validation_campaigns"]

    rows =
      Enum.flat_map(result["pairs"], fn pair ->
        pair["improvement"]
        |> Enum.sort()
        |> Enum.map(fn {name, improvement} ->
          "| #{pair["case_id"]} | #{name} | #{pair["control"][name]} | " <>
            "#{pair["variant"][name]} | #{improvement} |"
        end)
      end)

    gamed =
      Enum.flat_map(result["pairs"], fn pair ->
        Enum.map(pair["gamed"], &"- #{pair["case_id"]}: #{&1}")
      end)

    """
    # Meta confirmation of #{result["arms"]["variant"]}

    Plan `#{result["plan_id"]}` · verdict **#{result["verdict"]}** (#{result["reason"]}) · control #{result["arms"]["control"]} · variant #{result["arms"]["variant"]}

    This is development-grade evidence over n=#{n} validation inner campaign(s),
    one inner campaign per validation template: a sample of one per template.
    It says whether the proposer edit held up on a campaign it was never tuned
    on, not that the effect is established. Nothing here is activated.

    ## Pairs
    | campaign | objective | control | variant | improvement |
    | --- | --- | --- | --- | --- |
    #{Enum.join(rows, "\n")}

    Improvement is positive when the variant is better, in the objective's own
    units. Minimum effect: #{JSON.encode!(result["minimum_effect"])}.

    ## Gamed inner candidates (variant arm)
    #{if gamed == [], do: "(none)", else: Enum.join(gamed, "\n")}

    ## Resources
    #{JSON.encode!(result["resources"])} · elapsed #{result["timing"]["elapsed_ms"]} ms
    """
  end

  defp splits(inner, validation) when is_list(inner) and is_list(validation) do
    names = Enum.map(inner, fn {name, _template} -> Atom.to_string(name) end)
    validation = Enum.map(validation, &to_string/1)

    cond do
      names == [] -> {:error, :no_inner_campaigns}
      Enum.any?(validation, &(&1 not in names)) -> {:error, :unknown_validation_inner}
      validation == [] -> {:error, :validation_inner_required}
      names -- validation == [] -> {:error, :development_inner_required}
      true -> {:ok, names -- validation, validation}
    end
  end

  defp splits(_inner, _validation), do: {:error, :invalid_inner_campaigns}

  defp critic_profile(config, evolver) do
    case Keyword.get(config, :critic_profile, :default) do
      false ->
        nil

      %{} = profile ->
        profile

      :default ->
        Proposer.critic_profile(evolver["model"],
          quota: evolver["options"]["usage_mode"] == "quota"
        )
    end
  end

  defp artifact(artifacts, digest) do
    case Map.fetch(artifacts, digest) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:candidate_content_missing, digest}}
    end
  end

  defp decode(bytes) do
    case JSON.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :candidate_content_not_json}
    end
  end

  defp live_allowed(config, provider) do
    cond do
      Keyword.get(config, :allow_live, false) == true -> :ok
      match?({Scripted, _}, resolve(provider)) -> :ok
      true -> {:error, :live_campaign_requires_allow_live}
    end
  end

  defp resolve(provider) when is_function(provider, 0), do: provider.()
  defp resolve(provider), do: provider

  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")

  defp fetch(config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _missing -> {:error, {key, :required}}
    end
  end
end
