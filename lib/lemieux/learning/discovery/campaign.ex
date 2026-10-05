defmodule Lemieux.Learning.Discovery.Campaign do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A standalone-host discovery campaign: plan, search, persist.

  A hosted deployment gives scheduling, persistence and activation to its
  orchestrating host, and `Lemieux.Learning.Discovery.Shadow` deliberately has
  none of them. A standalone host still needs to run a search on one machine and
  keep the archive, and that role has to live somewhere honest: this module
  is it. It freezes a plan from a trusted configuration, wires the
  first-party proposer and the benchmark-backed evaluator into the search
  loop, records the corpus exposure before the first model call, and writes
  every candidate, evaluation, artifact and state projection to a directory
  as the search produces them, so an interrupted campaign leaves a readable
  archive rather than a lost budget.

  What it refuses to do is as important as what it does. It never activates
  a candidate, never reads a holdout, never runs against a live provider
  unless the caller says `allow_live: true`, and never writes into a
  directory that already holds a campaign. A frontier member it reports is a
  development result; the confirmation lane in
  `Lemieux.Learning.Extension.Confirmation` remains the only path to a qualified
  claim.
  """

  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Contract
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Evaluator
  alias Lemieux.Learning.Discovery.Frontier
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy
  alias Lemieux.Learning.Discovery.Shadow
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  @default_objectives [
    %{"name" => "task_success", "direction" => "maximize"},
    %{"name" => "requests", "direction" => "minimize"}
  ]
  @default_surface ["options.system", "options.tool_descriptions"]
  @default_max_content_bytes 32_000
  # A function, not an attribute: computing the digest at compile time would
  # make this module recompile whenever the contract module changes.
  defp trusted_local,
    do: %{"id" => "trusted-local", "sha256" => Contract.sha256("trusted-local")}

  @typedoc """
  A trusted, executable campaign configuration. Required: `:id`,
  `:manifest` (path), `:seed_profile`, `:development_case_ids`,
  `:validation_case_ids`, `:budget`, `:provider`, `:output_dir`, and either
  `:evolver_profile` or `:proposer_model`. Optional: `:scope`,
  `:mutation_surface`, `:objectives`, `:hard_constraints`, `:search`,
  `:models` (a portfolio: each case is evaluated on every listed model, see
  `Lemieux.Learning.Discovery.Evaluator.run/3`), `:proposer_provider`,
  `:critic_profile` (`false` disables the critic),
  `:sessions_dir`, `:benchmark`, `:session`, `:timeout_ms`, `:allow_live`.
  """
  @type config :: keyword()

  @doc "Freezes the discovery plan and seed bytes for a configuration."
  @spec plan(config :: config(), manifest_sha256 :: String.t()) ::
          {:ok, Plan.t(), binary()} | {:error, term()}
  def plan(config, manifest_sha256) when is_list(config) and is_binary(manifest_sha256) do
    with {:ok, seed_profile} <- fetch(config, :seed_profile),
         :ok <- Profile.validate(seed_profile),
         {:ok, evolver} <- evolver_profile(config),
         {:ok, budget} <- fetch(config, :budget),
         {:ok, id} <- fetch(config, :id) do
      seed_bytes = Contract.encode!(seed_profile)
      scope = %{"id" => Keyword.get(config, :scope, "local/" <> id)}

      attrs = %{
        "id" => id,
        "scope" => scope,
        "target_interface" => %{"id" => "lemieux.session-profile/v1"},
        "mutation_surface" =>
          config |> Keyword.get(:mutation_surface, @default_surface) |> Enum.map(&%{"path" => &1}),
        "seeds" => [
          %{"id" => "seed", "content_sha256" => Contract.sha256(seed_bytes), "scope" => scope}
        ],
        "proposer" => Proposer.identity(evolver),
        "base_model" => %{
          "id" => seed_profile["model"],
          "sha256" => Contract.sha256(seed_profile["model"])
        },
        "development_case_ids" => Keyword.get(config, :development_case_ids, []),
        "validation_case_ids" => Keyword.get(config, :validation_case_ids, []),
        "objectives" => objectives(config),
        "hard_constraints" => constraints(config),
        "interface_validator" => Surface.validator(),
        "budget" => budget,
        "extensions" => %{
          "search" => Keyword.get(config, :search, %{}),
          "campaign" => %{
            "manifest_sha256" => manifest_sha256,
            "evolver_profile_sha256" => Contract.digest(evolver)
          }
        }
      }

      with {:ok, plan} <- Plan.new(attrs), do: {:ok, plan, seed_bytes}
    end
  end

  @doc """
  Runs the campaign and persists the archive under `:output_dir`.

  Returns the shadow result on completion. A failed search returns
  `{:error, reason, state}` after persisting the state it reached.
  """
  @spec run(config :: config()) ::
          {:ok, Shadow.result()} | {:error, term()} | {:error, term(), State.t()}
  def run(config) when is_list(config) do
    with {:ok, output_dir} <- fetch(config, :output_dir),
         {:ok, provider} <- fetch(config, :provider),
         :ok <- live_allowed(config, provider),
         {:ok, manifest_path} <- fetch(config, :manifest),
         {:ok, manifest_bytes} <- File.read(manifest_path),
         {:ok, manifest} <- Manifest.read(manifest_path),
         {:ok, plan, seed_bytes} <- plan(config, Contract.sha256(manifest_bytes)),
         :ok <- cases_present(plan, manifest),
         :ok <- fresh_directory(output_dir),
         {:ok, exposure} <- expose(plan, manifest, config),
         :ok <- write_preamble(output_dir, plan, seed_bytes, exposure) do
      evolver = elem(evolver_profile(config), 1)

      proposer_context = %{
        workspace_root: Path.join(output_dir, "proposals"),
        provider: Keyword.get(config, :proposer_provider, provider),
        evolver_profile: evolver,
        critic_profile: critic_profile(config, evolver),
        sessions_dir: sessions_dir(config, output_dir),
        timeout_ms: Keyword.get(config, :timeout_ms, :timer.minutes(10))
      }

      proposer = fn plan, state, context ->
        Proposer.propose(plan, state, Map.merge(context, proposer_context))
      end

      evaluator = fn plan, candidate, context ->
        evaluate(plan, candidate, context, manifest, provider, config, output_dir)
      end

      result =
        Shadow.run(plan, proposer, evaluator,
          mode: :shadow,
          sandbox: trusted_local(),
          exposed_corpus: %{"id" => "manifest", "sha256" => Contract.sha256(manifest_bytes)},
          search: true,
          artifacts: %{Contract.sha256(seed_bytes) => seed_bytes},
          policy: Keyword.get(config, :search, %{}),
          observer: &persist(output_dir, &1),
          proposer_context: %{},
          evaluator_context: %{}
        )

      persist_result(output_dir, plan, result)
    end
  end

  @doc """
  Resumes an interrupted campaign from the archive under `:output_dir`.

  The persisted plan is authoritative: the configuration must still name the
  same evolver profile and seed, and the persisted state must be running or
  budget-exhausted. Recorded candidates and evaluations are loaded and never
  repeated; the search continues from the next selection.
  """
  @spec resume(config :: config()) ::
          {:ok, Shadow.result()} | {:error, term()} | {:error, term(), State.t()}
  def resume(config) when is_list(config) do
    with {:ok, output_dir} <- fetch(config, :output_dir),
         {:ok, provider} <- fetch(config, :provider),
         :ok <- live_allowed(config, provider),
         {:ok, manifest_path} <- fetch(config, :manifest),
         {:ok, manifest_bytes} <- File.read(manifest_path),
         {:ok, manifest} <- Manifest.read(manifest_path),
         {:ok, plan} <- read_plan(output_dir),
         {:ok, evolver} <- evolver_profile(config),
         :ok <- same_campaign(plan, evolver, Contract.sha256(manifest_bytes)),
         {:ok, archive} <- do_read_archive(output_dir, plan) do
      proposer_context = %{
        workspace_root: Path.join(output_dir, "proposals"),
        provider: Keyword.get(config, :proposer_provider, provider),
        evolver_profile: evolver,
        critic_profile: critic_profile(config, evolver),
        sessions_dir: sessions_dir(config, output_dir),
        timeout_ms: Keyword.get(config, :timeout_ms, :timer.minutes(10))
      }

      proposer = fn plan, state, context ->
        Proposer.propose(plan, state, Map.merge(context, proposer_context))
      end

      evaluator = fn plan, candidate, context ->
        evaluate(plan, candidate, context, manifest, provider, config, output_dir)
      end

      result =
        Shadow.run(plan, proposer, evaluator,
          mode: :shadow,
          sandbox: trusted_local(),
          exposed_corpus: %{"id" => "manifest", "sha256" => Contract.sha256(manifest_bytes)},
          search: true,
          artifacts: archive.artifacts,
          policy: Keyword.get(config, :search, %{}),
          observer: &persist(output_dir, &1),
          resume: archive
        )

      persist_result(output_dir, plan, result)
    end
  end

  @doc """
  Reads the frozen plan an archive was written under.

  Public because the archive, not the configuration, is authoritative on
  resume — `Lemieux.Learning.Discovery.Meta` reads the same file for the same
  reason, and a second implementation of "where the plan lives" would be a
  second place for that rule to drift.
  """
  @spec read_plan(dir :: Path.t()) :: {:ok, Plan.t()} | {:error, term()}
  def read_plan(dir) when is_binary(dir) do
    with {:ok, bytes} <- File.read(Path.join(dir, "plan.json")), do: Plan.decode(bytes)
  end

  defp same_campaign(plan, evolver, manifest_sha256) do
    cond do
      plan.proposer != Proposer.identity(evolver) ->
        {:error, :resume_evolver_profile_mismatch}

      get_in(plan.extensions, ["campaign", "manifest_sha256"]) != manifest_sha256 ->
        {:error, :resume_manifest_mismatch}

      true ->
        :ok
    end
  end

  @doc """
  Loads the candidates, evaluations, artifacts and state a campaign persisted.

  This is what `Lemieux.Learning.Discovery.Shadow`'s `:resume` option takes.
  Public for the same reason `read_plan/1` is: the meta campaign resumes its
  own outer search from an archive written by this module.
  """
  @spec read_archive(dir :: Path.t(), plan :: Plan.t()) :: {:ok, map()} | {:error, term()}
  def read_archive(dir, %Plan{} = plan) when is_binary(dir), do: do_read_archive(dir, plan)

  @doc """
  Reconstructs a finished campaign's result from its archive.

  A campaign that has already been paid for is evidence, and re-running it
  would buy the same evidence twice. `finished?/1` says whether a directory
  holds one; this turns it back into the `Lemieux.Learning.Discovery.Shadow`
  result a caller would have received, so the meta campaign can score an
  inner run it did not have to repeat.

  The frontier, calibration, digest, selection and acceptance projections come
  from the files `run/1` wrote; anything a build wrote no file for is `nil`
  rather than recomputed, because recomputing it here would claim the archive
  said something it did not.
  """
  @spec read_result(dir :: Path.t()) :: {:ok, Shadow.result()} | {:error, term()}
  def read_result(dir) when is_binary(dir) do
    with {:ok, plan} <- read_plan(dir),
         {:ok, archive} <- do_read_archive(dir, plan),
         {:ok, bytes} <- File.read(Path.join(dir, "frontier.json")),
         {:ok, frontier} <- Frontier.decode(plan, bytes) do
      {:ok,
       %{
         state: archive.state,
         candidates: archive.candidates,
         evaluations: archive.evaluations,
         artifacts: archive.artifacts,
         incomplete: archive.incomplete,
         frontier: frontier,
         calibration: optional_json(dir, "calibration.json"),
         digest: optional_json(dir, "digest.json"),
         selection: optional_json(dir, "selection.json"),
         acceptance: optional_json(dir, "acceptance.json")
       }}
    end
  end

  @doc """
  Whether `dir` holds a campaign that ran to a result.

  `frontier.json` is the marker because `run/1` writes it only on the success
  path: a directory with a `state.json` and no frontier is an interrupted
  campaign to resume, and an empty or absent directory is one to start.
  """
  @spec finished?(dir :: Path.t()) :: boolean()
  def finished?(dir) when is_binary(dir), do: File.exists?(Path.join(dir, "frontier.json"))

  @doc "Whether `dir` holds an archive that was started and never finished."
  @spec interrupted?(dir :: Path.t()) :: boolean()
  def interrupted?(dir) when is_binary(dir),
    do: File.exists?(Path.join(dir, "state.json")) and not finished?(dir)

  defp optional_json(dir, name) do
    with {:ok, bytes} <- File.read(Path.join(dir, name)),
         {:ok, value} <- JSON.decode(bytes) do
      value
    else
      _unreadable -> nil
    end
  end

  defp do_read_archive(dir, plan) do
    with {:ok, state_bytes} <- File.read(Path.join(dir, "state.json")),
         {:ok, state} <- State.decode(plan, state_bytes),
         {:ok, candidates} <- read_all(Path.join(dir, "candidates"), &Candidate.decode(plan, &1)),
         {:ok, evaluations} <- read_evaluations(Path.join(dir, "evaluations"), plan, candidates) do
      artifacts =
        dir
        |> Path.join("artifacts")
        |> File.ls!()
        |> Map.new(&{&1, File.read!(Path.join([dir, "artifacts", &1]))})

      incomplete =
        case File.read(Path.join(dir, "incomplete.jsonl")) do
          {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
          {:error, _} -> []
        end

      {:ok,
       %{
         state: state,
         candidates: candidates,
         evaluations: evaluations,
         artifacts: artifacts,
         incomplete: incomplete
       }}
    end
  end

  defp read_all(dir, decoder) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, built} ->
      case decoder.(File.read!(Path.join(dir, name))) do
        {:ok, value} -> {:cont, {:ok, [value | built]}}
        {:error, reason} -> {:halt, {:error, {:archive_unreadable, name, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp read_evaluations(dir, plan, candidates) do
    index = Map.new(candidates, &{&1.id, &1})

    read_all(dir, fn bytes ->
      with {:ok, map} <- Contract.decode(bytes),
           %Candidate{} = candidate <-
             Map.get(index, map["candidate_id"], {:error, :unknown_candidate}) do
        Evaluation.decode(plan, candidate, bytes)
      end
    end)
  end

  @doc false
  @spec observer(output_dir :: Path.t()) :: (term() -> :ok)
  def observer(output_dir) when is_binary(output_dir), do: &persist(output_dir, &1)

  @doc false
  @spec finish(output_dir :: Path.t(), plan :: Plan.t(), result :: term()) :: term()
  def finish(output_dir, %Plan{} = plan, result), do: persist_result(output_dir, plan, result)

  @doc false
  @spec preamble(output_dir :: Path.t(), plan :: Plan.t(), seed_bytes :: binary()) ::
          :ok | {:error, term()}
  def preamble(output_dir, %Plan{} = plan, seed_bytes) when is_binary(seed_bytes) do
    with :ok <- fresh_directory(output_dir),
         :ok <- File.mkdir_p(Path.join(output_dir, "seed")),
         :ok <-
           Enum.each(
             ~w(candidates evaluations artifacts),
             &File.mkdir_p!(Path.join(output_dir, &1))
           ),
         :ok <- File.write(Path.join(output_dir, "plan.json"), Plan.encode!(plan)),
         :ok <- File.write(Path.join(output_dir, "seed/profile.json"), seed_bytes) do
      File.write(Path.join(output_dir, "artifacts/" <> Contract.sha256(seed_bytes)), seed_bytes)
    end
  end

  @doc "Renders a human-readable campaign report."
  @spec report(plan :: Plan.t(), result :: Shadow.result()) :: String.t()
  def report(%Plan{} = plan, result) when is_map(result) do
    members = MapSet.new(Enum.map(result.frontier.members, & &1["candidate_id"]))
    excluded = Map.new(result.frontier.excluded, &{&1["candidate_id"], &1["reason"]})
    scores = Map.new(result.frontier.members, &{&1["candidate_id"], &1["scores"]})
    policy = Policy.read(plan)

    rows =
      Enum.map_join(
        result.candidates,
        "\n",
        &candidate_row(&1, result.evaluations, policy, members, excluded)
      )

    calibration = result.calibration || %{}

    """
    # Discovery campaign #{plan.id}

    Plan `#{plan.sha256}` · status **#{result.state.status}** · budget #{JSON.encode!(result.state.budget)}

    This is a development result over exposed cases. Nothing here is confirmed
    or activated; freeze a frontier member and run the confirmation lane on
    fresh cases before claiming an improvement.

    ## Frontier
    #{frontier_lines(members, scores)}

    ## Candidates
    | id | operator | parent | changed paths | dev passed | critic | fate |
    | --- | --- | --- | --- | --- | --- | --- |
    #{rows}

    ## Proposer calibration
    status: #{calibration["status"]} · aggregate: #{JSON.encode!(calibration["aggregate"] || %{})}

    ## Acceptance by operator
    #{JSON.encode!(result.acceptance || %{})}

    ## Failure clusters
    #{cluster_lines(result)}

    Incomplete attempts: #{length(result.incomplete)}
    """
  end

  # "dev passed" counts cases, not evaluations: a case is solved only when
  # every attempt on it succeeded, so a policy that repeats a case cannot
  # report 2/3 for one solved case and one flaky one.
  defp candidate_row(%Candidate{} = candidate, all_evaluations, policy, members, excluded) do
    by_case =
      all_evaluations
      |> Enum.filter(&(&1.candidate_id == candidate.id and &1.split == "development"))
      |> Enum.group_by(& &1.case_id)

    solved =
      Enum.count(by_case, fn {_case_id, runs} -> Enum.all?(runs, &Policy.success?(&1, policy)) end)

    parent = Enum.map_join(candidate.parents, ",", & &1["id"])

    "| #{candidate.id} | #{candidate.mutation_kind} | #{parent} | " <>
      "#{Enum.join(get_in(candidate.extensions, ["changed_paths"]) || [], ", ")} | " <>
      "#{solved}/#{map_size(by_case)} | #{get_in(candidate.extensions, ["critic", "verdict"])} | #{fate(candidate.id, members, excluded)} |"
  end

  defp fate(candidate_id, members, excluded) do
    cond do
      MapSet.member?(members, candidate_id) -> "frontier"
      Map.has_key?(excluded, candidate_id) -> excluded[candidate_id]
      true -> "dominated"
    end
  end

  defp frontier_lines(members, scores) do
    if members == MapSet.new(),
      do: "(no eligible member)",
      else: Enum.map_join(members, "\n", &"- #{&1}: #{JSON.encode!(scores[&1])}")
  end

  defp cluster_lines(result) do
    Enum.map_join(
      get_in(result, [:digest, "clusters"]) || [],
      "\n",
      &"- #{&1["count"]}× #{JSON.encode!(&1["signature"])} cases=#{Enum.join(&1["case_ids"], ",")}"
    )
  end

  # ---------------------------------------------------------------------------

  defp evaluate(plan, candidate, context, manifest, provider, config, output_dir) do
    digest = Candidate.content_sha256(candidate)

    with {:ok, bytes} <- Map.fetch(context.artifacts, digest) |> content_result(digest),
         {:ok, profile} <- decode(bytes) do
      Evaluator.run(plan, candidate,
        manifest: manifest,
        profile: profile,
        provider: provider,
        models: Keyword.get(config, :models),
        case_ids: context.case_ids,
        attempts: Map.get(context, :attempts, %{}),
        sandbox: :not_applicable,
        unknown_cost: plan.budget["unknown_cost"] || "reject",
        sessions_dir: sessions_dir(config, output_dir),
        session: Keyword.get(config, :session, []),
        benchmark:
          Keyword.merge(
            [workspace_root: Path.join(output_dir, "workspaces"), max_concurrency: 1],
            Keyword.get(config, :benchmark, [])
          )
      )
    end
  end

  defp content_result({:ok, bytes}, _digest), do: {:ok, bytes}
  defp content_result(:error, digest), do: {:error, {:candidate_content_missing, digest}}

  defp decode(bytes) do
    case JSON.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :candidate_content_not_json}
    end
  end

  # With a model portfolio, each model's task success is its own objective
  # beside the mean, so the frontier keeps a candidate that is best on one
  # model visible instead of averaging it away.
  defp objectives(config) do
    base = Keyword.get(config, :objectives, @default_objectives)

    per_model =
      config
      |> Keyword.get(:models, [])
      |> Enum.map(&model_name/1)
      |> Enum.map(&%{"name" => "task_success@" <> &1, "direction" => "maximize"})

    base ++ per_model
  end

  defp model_name(model) when is_binary(model), do: model
  defp model_name(%{"model" => model}), do: model

  defp evolver_profile(config) do
    case Keyword.get(config, :evolver_profile) do
      %{} = profile ->
        {:ok, profile}

      nil ->
        case Keyword.get(config, :proposer_model) do
          model when is_binary(model) ->
            {:ok, Proposer.profile(model, quota: Keyword.get(config, :quota, false))}

          _missing ->
            {:error, {:evolver_profile, :required}}
        end
    end
  end

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

  defp constraints(config) do
    extra = Keyword.get(config, :hard_constraints, [])
    patterns = Keyword.get(config, :forbidden_references, []) ++ ["grader", "solution"]

    [
      %{"id" => "trusted-local", "kind" => "mechanical", "sandbox" => "not_applicable"},
      %{"id" => "no-solved-regression", "kind" => "no_solved_regression"},
      %{
        "id" => "max-content-bytes",
        "kind" => "max_content_bytes",
        "value" => Keyword.get(config, :max_content_bytes, @default_max_content_bytes)
      },
      %{
        "id" => "forbidden-references",
        "kind" => "forbidden_references",
        "patterns" => Enum.uniq(patterns)
      }
    ] ++ extra
  end

  @doc "Grader script names in a manifest, for the forbidden-references constraint."
  @spec grader_references(manifest :: Manifest.t()) :: [String.t()]
  def grader_references(%Manifest{tasks: tasks}) do
    tasks
    |> Enum.flat_map(fn task -> task.grader.command end)
    |> Enum.filter(&(is_binary(&1) and Regex.match?(~r/^[\w.\/-]+\.(sh|exs|ex|py|rb|js)$/, &1)))
    |> Enum.map(&Path.basename/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cases_present(plan, manifest) do
    ids = MapSet.new(Enum.map(manifest.tasks, & &1.id))

    case Enum.find(
           plan.development_case_ids ++ plan.validation_case_ids,
           &(not MapSet.member?(ids, &1))
         ) do
      nil -> :ok
      missing -> {:error, {:case_not_in_manifest, missing}}
    end
  end

  defp expose(plan, manifest, config) do
    membership =
      Map.new(manifest.tasks, fn task ->
        cond do
          task.id in plan.development_case_ids -> {task.id, :development}
          task.id in plan.validation_case_ids -> {task.id, :validation}
          true -> {task.id, :holdout}
        end
      end)

    with {:ok, corpus} <- Corpus.new(manifest, membership),
         {:ok, corpus} <-
           Corpus.expose(corpus, plan.development_case_ids ++ plan.validation_case_ids, %{
             consumer_role: "discovery_proposer",
             consumer_id: plan.id,
             lineage_id: plan.id,
             model:
               Keyword.get(config, :proposer_model) || get_in(config, [:evolver_profile, "model"]),
             context_digest: plan.sha256,
             experiment_id: plan.id
           }) do
      [exposure | _] = Corpus.exposures(corpus, hd(plan.development_case_ids))
      {:ok, exposure}
    end
  end

  defp live_allowed(config, provider) do
    cond do
      Keyword.get(config, :allow_live, false) == true ->
        :ok

      scripted?(resolve(provider)) and
          scripted?(resolve(Keyword.get(config, :proposer_provider, provider))) ->
        :ok

      true ->
        {:error, :live_campaign_requires_allow_live}
    end
  end

  defp scripted?({Scripted, _state}), do: true
  defp scripted?(_provider), do: false

  defp resolve(provider) when is_function(provider, 0), do: provider.()
  defp resolve(provider), do: provider

  defp sessions_dir(config, output_dir),
    do: Keyword.get(config, :sessions_dir, Path.join(output_dir, "sessions"))

  defp fresh_directory(dir) do
    if File.exists?(dir) and File.ls!(dir) != [],
      do: {:error, {:output_dir_not_empty, dir}},
      else: File.mkdir_p(dir)
  end

  defp write_preamble(dir, plan, seed_bytes, exposure) do
    with :ok <- File.mkdir_p(Path.join(dir, "seed")),
         :ok <-
           Enum.each(~w(candidates evaluations artifacts), &File.mkdir_p!(Path.join(dir, &1))),
         :ok <- File.write(Path.join(dir, "plan.json"), Plan.encode!(plan)),
         :ok <- File.write(Path.join(dir, "seed/profile.json"), seed_bytes),
         :ok <-
           File.write(Path.join(dir, "artifacts/" <> Contract.sha256(seed_bytes)), seed_bytes) do
      File.write(Path.join(dir, "exposure.json"), Exposure.encode!(exposure))
    end
  end

  defp persist(dir, {:candidate, %Candidate{} = candidate, artifacts}) do
    File.write!(
      Path.join([dir, "candidates", safe(candidate.id) <> ".json"]),
      Candidate.encode!(candidate)
    )

    write_artifacts(dir, artifacts)
  end

  defp persist(dir, {:evaluations, evaluations, artifacts, incomplete}) do
    Enum.each(evaluations, fn %Evaluation{} = evaluation ->
      File.write!(
        Path.join([dir, "evaluations", safe(evaluation.id) <> ".json"]),
        Evaluation.encode!(evaluation)
      )
    end)

    write_artifacts(dir, artifacts)

    if incomplete != [] do
      File.write!(
        Path.join(dir, "incomplete.jsonl"),
        Enum.map_join(incomplete, "", &(JSON.encode!(&1) <> "\n")),
        [:append]
      )
    end
  end

  defp persist(dir, {:state, %State{} = state}),
    do: File.write!(Path.join(dir, "state.json"), State.encode!(state))

  defp write_artifacts(dir, artifacts) do
    Enum.each(artifacts, fn {sha, bytes} ->
      path = Path.join([dir, "artifacts", sha])
      if not File.exists?(path), do: File.write!(path, bytes)
    end)
  end

  defp persist_result(dir, plan, {:ok, result}) do
    File.write!(Path.join(dir, "state.json"), State.encode!(result.state))

    File.write!(Path.join(dir, "frontier.json"), Frontier.encode!(result.frontier))

    File.write!(Path.join(dir, "calibration.json"), JSON.encode!(result.calibration))
    File.write!(Path.join(dir, "digest.json"), JSON.encode!(result.digest))
    File.write!(Path.join(dir, "selection.json"), JSON.encode!(result.selection))
    # Written so the archive is enough to reconstruct the result. Without it a
    # reader had to rerun the campaign to learn which operators were accepted.
    File.write!(Path.join(dir, "acceptance.json"), JSON.encode!(result.acceptance))
    File.write!(Path.join(dir, "report.md"), report(plan, result))
    {:ok, result}
  end

  defp persist_result(dir, _plan, {:error, reason, %State{} = state}) do
    File.write!(Path.join(dir, "state.json"), State.encode!(state))
    File.write!(Path.join(dir, "error.json"), JSON.encode!(%{"error" => Contract.json(reason)}))
    {:error, reason, state}
  end

  defp persist_result(_dir, _plan, {:error, reason}), do: {:error, reason}

  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")

  defp fetch(config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _missing -> {:error, {key, :required}}
    end
  end
end
