defmodule Lemieux.Learning.Proposer do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  First-party discovery proposer: digester, planner, evolver, critic.

  This is the search half of harness self-improvement, built as an ordinary
  extension so it inherits the workbench, freeze and confirmation lane and
  can itself become a discovery candidate (Hyperagents' editable meta-level,
  with no new activation path). It implements
  `Lemieux.Learning.Discovery.Proposer` for the shadow loop and `Lemieux.Agent`
  so hosts and benchmarks can run it like any other extension.

  The four stages follow the shape Self-Harness, HarnessX and HarnessFix
  converged on, and each is a separate seam because each fails differently:

    * **Digester** (`Lemieux.Learning.Discovery.Digest`, pure) clusters
      failures by verifier cause, causal status and mechanism, so the model
      reads a triage index instead of raw trajectories.
    * **Planner** (pure, `landscape/1`) lays out every prior candidate with
      what it changed, how it scored and whether it was accepted or rejected,
      so the same edit is not proposed twice — the rejected-edit buffer every
      2026 system keeps.
    * **Evolver** (one bounded model session) reads a sealed workspace and
      writes one complete profile document plus a manifest that names the
      cluster it targets and predicts which cases it fixes and which it puts
      at risk. The prediction is what makes the edit falsifiable and what
      `Lemieux.Learning.Discovery.Calibration` later scores.
    * **Critic** (one tool-less session, optional) compares the manifest with
      the trace evidence before any paid evaluation and may veto. A veto is
      recorded on the candidate rather than discarded, so a vetoed idea is
      still visible to the next proposer.

  Every proposal becomes a candidate, including one whose document fails the
  surface validator: recording the failure is how the archive learns what the
  proposer keeps getting wrong. Only an infrastructure failure before any
  content exists is returned as an error. The proposer never evaluates,
  never touches a holdout, and never activates anything; the plan it receives
  has no holdout key by construction.
  """

  @behaviour Lemieux.Agent
  @behaviour Lemieux.Learning.Discovery.Proposer

  alias Lemieux.Agent.Session, as: AgentSession
  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Learning.Proposer.Workspace

  @identity_id "Lemieux.Learning.Proposer"
  @content_schema "lemieux.session-profile/v1"

  @evolver_system """
  You are Lemieux's harness proposer. You improve a coding agent's harness profile,
  not the model's weights and not the tasks. The profile is JSON: a system prompt,
  tool list, per-tool descriptions and generation bounds. You may change ONLY the
  paths listed in plan.json under mutation_surface; every other value must stay
  exactly as in parent/profile.json.

  Work from evidence, not intuition. Read evidence/summary.md, then the cluster
  you are targeting in evidence/digest.json, then the transcript excerpts under
  evidence/transcripts/ and evidence/landscape.json to see what earlier candidates
  already tried and how they scored. Propose ONE minimal edit that addresses one
  failure mechanism with cross-case support. Do not rewrite unrelated text.
  Never mention graders, check scripts, hidden cases or the benchmark; the
  validator rejects documents that do. Keep the document small.

  Output contract, both files under proposal/:
  1. proposal/profile.json — the COMPLETE profile document (copy parent/profile.json
     and apply your edit). Valid JSON. Same top-level keys.
  2. proposal/manifest.json — JSON with exactly these keys:
     rationale (string), hypothesis (one falsifiable sentence),
     targeted_cluster (the signature object from the digest, or null),
     mechanism (string), changed_paths (list of dotted paths you changed),
     predicted_fixes (list of development case ids you expect to flip to passing),
     predicted_at_risk (list of case ids your edit could regress; be honest).
  Write both files with the write tool, then answer with a two-sentence summary.
  Keep your reasoning short and write the files early: a reply that runs out
  of room before the write tool is a wasted proposal.
  Record a prediction even when uncertain: an unfalsifiable edit cannot be scored.
  """

  @critic_system """
  You are Lemieux's proposal critic. You receive a proposed harness edit, its
  manifest, and bounded evidence from the transcripts it claims to address.
  Decide whether the trace evidence supports the diagnosis and whether the edit
  is minimal, inside the declared surface, and free of grader or benchmark
  references. Do not evaluate whether it will work; that is what the paid
  evaluation is for. Answer with JSON only: {"verdict": "accept" | "veto",
  "reason": "one or two sentences"}. Veto only for a diagnosis the evidence
  contradicts, an edit that touches unrelated text, or a grader reference.
  """

  @doc "The evolver profile; the host selects the model and may enable quota mode."
  @spec profile(model :: String.t(), opts :: keyword()) :: map()
  def profile(model, opts \\ []) when is_binary(model) do
    profile = %{
      "execution" => "live",
      "model" => model,
      "tools" => ["read", "write", "edit"],
      "options" => %{
        "system" => @evolver_system,
        "max_turns" => Keyword.get(opts, :max_turns, 16),
        # A reasoning model narrating a cross-lineage analysis overran 4096
        # output tokens and stopped at `length` with nothing written, twice
        # in one cycle; the bound is for runaway output, not for thinking.
        "max_tokens" => Keyword.get(opts, :max_tokens, 16_384),
        "max_cost_usd" => Keyword.get(opts, :max_cost_usd, 1.0),
        "reasoning_effort" => Keyword.get(opts, :reasoning_effort, default_effort(model)),
        "temperature" => Keyword.get(opts, :temperature, 0.3)
      }
    }

    if opts[:quota],
      do: Profile.quota(profile, Keyword.get(opts, :max_requests, 20)),
      else: profile
  end

  @doc "The tool-less critic profile."
  @spec critic_profile(model :: String.t(), opts :: keyword()) :: map()
  def critic_profile(model, opts \\ []) when is_binary(model) do
    profile = %{
      "execution" => "live",
      "model" => model,
      "tools" => [],
      "options" => %{
        "system" => @critic_system,
        "max_turns" => 2,
        "max_tokens" => Keyword.get(opts, :max_tokens, 4096),
        "max_cost_usd" => Keyword.get(opts, :max_cost_usd, 0.25),
        "reasoning_effort" => Keyword.get(opts, :reasoning_effort, default_effort(model)),
        "temperature" => 0.0
      }
    }

    if opts[:quota],
      do: Profile.quota(profile, Keyword.get(opts, :max_requests, 2)),
      else: profile
  end

  # GLM-5.3 on Z.AI Coding Plan takes the low-effort recipe the extension
  # builder measured on 2026-09-14: with default effort its thinking can use
  # the whole output allowance and leave no visible answer, which is what the
  # first live critic session did. Other models keep provider-default effort.
  defp default_effort("zai_coding_plan:glm-5.3"), do: "low"
  defp default_effort(_model), do: "default"

  @doc """
  The immutable identity a plan pins as its `proposer`: the module name and
  the digest of the evolver profile actually used.
  """
  @spec identity(evolver_profile :: map()) :: %{String.t() => String.t()}
  def identity(evolver_profile) when is_map(evolver_profile),
    do: %{"id" => @identity_id, "sha256" => Contract.digest(evolver_profile)}

  @impl Lemieux.Agent
  def configure(profile), do: Profile.configure(profile)

  @impl Lemieux.Agent
  def run(input, opts), do: Profile.run(input, opts)

  @doc """
  Proposes one candidate. See the module documentation for the stages.

  Required context: `:parent` (`{:seed, seed} | {:candidate, id}`),
  `:operator`, `:candidates`, `:evaluations`, `:artifacts` (SHA-256 to bytes,
  including every candidate's content), `:ordinal`, `:workspace_root`,
  `:provider`, `:evolver_profile`. Optional: `:evidence`, `:digest`,
  `:calibration`, `:frontier_ids`, `:critic_profile` (omit to skip the
  critic), `:sessions_dir`, `:timeout_ms`, `:retain` (a function receiving
  the new content's SHA-256 and bytes).

  The evolver session works in `proposal-NNN` under `:workspace_root`, NNN
  being the `:ordinal`, or in `proposal-NNN-rK` when an earlier attempt at
  that ordinal left its directory there. Such an attempt's evidence is still
  read-only if it was killed during its session, and gets its write
  permission back before the new session starts, so two proposals for the
  same ordinal must not run under one root at once.
  """
  @impl Lemieux.Learning.Discovery.Proposer
  @spec propose(plan :: Plan.t(), state :: State.t(), context :: map()) ::
          {:ok, Candidate.t(), map()} | :done | {:error, term()}
  def propose(%Plan{} = plan, %State{}, context) when is_map(context) do
    started = System.monotonic_time(:millisecond)

    with {:ok, parent_ref, parent_bytes} <- parent(plan, context),
         {:ok, parent_map} <- decode_profile(parent_bytes) do
      operator = Map.get(context, :operator, "clonal")

      if operator == "seed" do
        seed_candidate(plan, context, parent_ref, parent_bytes, parent_map, started)
      else
        evolve(plan, context, operator, parent_ref, parent_bytes, parent_map, started)
      end
    end
  end

  @doc "The planner's view of the archive: every candidate, its edit, scores and fate."
  @spec landscape(context :: map()) :: map()
  def landscape(context) when is_map(context) do
    candidates = Map.get(context, :candidates, [])
    evaluations = Map.get(context, :evaluations, [])
    frontier_ids = MapSet.new(Map.get(context, :frontier_ids, []))
    calibration = get_in(context, [:calibration, "candidates"]) || %{}
    policy = Map.get(context, :policy) || Policy.read(Map.fetch!(context, :plan))
    outcomes = outcomes(evaluations, policy)

    rows =
      Enum.map(candidates, fn %Candidate{} = candidate ->
        cases = Map.get(outcomes, candidate.id, %{})
        successes = Enum.count(cases, fn {_id, success} -> success end)

        %{
          "id" => candidate.id,
          "mutation_kind" => candidate.mutation_kind,
          "parents" => Enum.map(candidate.parents, & &1["id"]),
          "interface" => candidate.interface_validation["status"],
          "changed_paths" => get_in(candidate.extensions, ["changed_paths"]) || [],
          "hypothesis" => get_in(candidate.extensions, ["hypothesis"]),
          "critic" => get_in(candidate.extensions, ["critic", "verdict"]),
          "prediction" => Map.get(candidate.extensions, "prediction"),
          "calibration" => Map.get(calibration, candidate.id),
          "cases" => cases,
          "evaluated" => map_size(cases),
          "successes" => successes,
          "frontier_member" => MapSet.member?(frontier_ids, candidate.id)
        }
      end)

    %{"candidates" => rows, "count" => length(rows)}
  end

  defp seed_candidate(plan, context, parent_ref, bytes, parent_map, started) do
    validation = Surface.validate(plan, parent_map, parent_map, bytes, "seed")

    manifest = %{
      "rationale" => "Seed baseline: the parent document evaluated unchanged.",
      "hypothesis" =>
        "The seed's development outcomes are the reference every edit is scored against.",
      "changed_paths" => [],
      "predicted_fixes" => [],
      "predicted_at_risk" => []
    }

    build_candidate(plan, context, %{
      operator: "seed",
      parent_ref: parent_ref,
      bytes: bytes,
      manifest: manifest,
      validation: validation,
      critic: %{"verdict" => "not_applicable", "reason" => "seed baseline"},
      sessions: %{},
      # No session runs for the seed, so what it cost is known: nothing. `[]`
      # would say the opposite — `accounting/2` reads no usage as unknown cost,
      # which is right for an evolver whose usage went missing — and a metered
      # plan (no `"unknown_cost" => "allow"`) stopped its search after the seed.
      usages: [%{"input_tokens" => 0, "output_tokens" => 0, "cost_usd" => 0.0, "requests" => 0}],
      started: started
    })
  end

  defp evolve(plan, context, operator, parent_ref, parent_bytes, parent_map, started) do
    inputs = %{
      plan: plan,
      parent_bytes: parent_bytes,
      digest: Map.get(context, :digest, %{}),
      landscape: landscape(Map.put(context, :plan, plan)),
      operator: operator,
      parent_id: parent_ref["id"],
      evidence: Map.get(context, :evidence, %{}),
      calibration: Map.get(context, :calibration, %{}),
      evaluations: Map.get(context, :evaluations, []),
      artifacts: Map.get(context, :artifacts, %{}),
      instructions: instructions(plan, operator, Map.get(context, :evidence, %{}))
    }

    root = Map.fetch!(context, :workspace_root)
    ordinal = Map.fetch!(context, :ordinal)
    :ok = repair_stale_seals(root, ordinal)

    with {:ok, workspace} <- Workspace.materialize(root, ordinal, inputs) do
      prompt = level_prefix(Map.get(context, :level)) <> task_prompt(operator)
      sealed = Workspace.seal(workspace)

      # Unsealed on the way out, including when the session raises, throws or
      # exits in here. Not when this process is killed — an ExUnit timeout, a
      # supervisor's brutal kill, a linked process's exit — nor when the VM
      # stops: nothing in the process runs then, and the read-only tree stays.
      # `repair_stale_seals/2` gets it back when the ordinal is tried again.
      evolver =
        try do
          session(context, Map.fetch!(context, :evolver_profile), workspace.root, prompt)
        after
          Workspace.unseal(sealed)
        end

      case evolver do
        {:error, reason} ->
          {:error, {:evolver_failed, reason}}

        {:ok, evolver_observation} ->
          finish_evolution(plan, context, %{
            operator: operator,
            parent_ref: parent_ref,
            parent_map: parent_map,
            proposal: Workspace.proposal(workspace),
            evolver_observation: evolver_observation,
            workspace: workspace,
            started: started
          })
      end
    end
  end

  # An attempt killed mid-session leaves its evidence and parent trees
  # read-only (see the `after` in `evolve/7`). `rm -rf` of the campaign
  # directory then fails on them ("Permission denied"), and when that
  # directory was a test's tmp_dir, ExUnit could not recreate it on any later
  # run: one test timeout under load failed four test files from then on.
  #
  # Only this ordinal's earlier attempts are repaired: `proposal-NNN` and the
  # `proposal-NNN-rK` retries, the names `Workspace.materialize/3` gives. The
  # shadow loop (`Lemieux.Learning.Discovery.Shadow`) numbers a proposal after
  # the candidates already recorded, so an attempt that never returned is
  # retried under its own ordinal when the campaign resumes, and its sealed
  # tree belongs to an attempt that will never finish. A sweep of every
  # `proposal-*` would also unseal the evidence of another proposal running
  # under the same root, mid-session. The tree itself stays, as evidence,
  # beside the new workspace.
  #
  # Listed rather than matched with `Path.wildcard/1`: the root is a path the
  # host chose (a campaign's output directory), and a `[`, `{` or `*` in it
  # would make the pattern match another campaign's trees and miss its own.
  defp repair_stale_seals(root, ordinal) do
    attempt =
      ~r/\Aproposal-#{String.pad_leading(Integer.to_string(ordinal), 3, "0")}(-r[0-9]+)?\z/

    for name <- entries(root),
        Regex.match?(attempt, name),
        workspace = Path.join(root, name),
        tree <- [Path.join(workspace, "evidence"), Path.join(workspace, "parent")],
        sealed?(tree) do
      Workspace.unseal(%Workspace{
        root: workspace,
        proposal: Path.join(workspace, "proposal"),
        sealed: [tree]
      })
    end

    :ok
  end

  # The root does not exist before the campaign's first proposal.
  defp entries(root) do
    case File.ls(root) do
      {:ok, names} -> names
      {:error, _absent} -> []
    end
  end

  # Any directory without its owner's write permission, anywhere in the tree:
  # sealing works from the leaves up, so a kill partway through leaves the
  # top writable and what is under it not. A link is not followed: sealing
  # never makes one, and one could point anywhere.
  defp sealed?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        Bitwise.band(mode, 0o200) == 0 or
          path |> File.ls!() |> Enum.any?(&sealed?(Path.join(path, &1)))

      _file_link_or_gone ->
        false
    end
  end

  defp finish_evolution(plan, context, evolution) do
    %{operator: operator, evolver_observation: evolver_observation, workspace: workspace} =
      evolution

    {bytes, manifest, validation} =
      case evolution.proposal do
        {:ok, %{profile: profile, manifest: manifest, bytes: bytes}} ->
          {bytes, manifest,
           profile_validation(plan, evolution.parent_map, profile, bytes, operator)}

        {:error, reason} ->
          {"{}", %{}, {:error, reason}}
      end

    {critic, critic_observation} = critique(context, workspace, manifest, validation)

    build_candidate(plan, context, %{
      operator: operator,
      parent_ref: evolution.parent_ref,
      bytes: bytes,
      manifest: manifest,
      validation: validation,
      critic: critic,
      sessions: %{
        "evolver" => evolver_observation["session_id"],
        "critic" => critic_observation && critic_observation["session_id"]
      },
      usages:
        Enum.reject(
          [evolver_observation["usage"], critic_observation && critic_observation["usage"]],
          &is_nil/1
        ),
      started: evolution.started
    })
  end

  defp profile_validation(plan, parent_map, profile, bytes, operator) do
    with :ok <- Profile.validate(profile),
         {:ok, detail} <- Surface.validate(plan, parent_map, profile, bytes, operator) do
      {:ok, detail}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp critique(context, workspace, manifest, {:ok, _detail}) do
    case Map.get(context, :critic_profile) do
      nil ->
        {%{"verdict" => "skipped", "reason" => "no critic profile supplied"}, nil}

      profile ->
        prompt = critic_prompt(manifest, workspace)

        case session(context, profile, workspace.root, prompt) do
          {:ok, observation} -> {parse_verdict(observation["answer"]), observation}
          {:error, reason} -> {%{"verdict" => "unavailable", "reason" => inspect(reason)}, nil}
        end
    end
  end

  defp critique(_context, _workspace, _manifest, {:error, _reason}),
    do: {%{"verdict" => "not_applicable", "reason" => "interface validation failed"}, nil}

  defp build_candidate(plan, context, parts) do
    content =
      ArtifactReference.from_bytes("candidate_content", parts.bytes,
        media_type: "application/json",
        content_schema: @content_schema,
        scope: plan.scope
      )

    manifest = parts.manifest

    prediction = %{
      "fixes" => ids(manifest["predicted_fixes"]),
      "at_risk" => ids(manifest["predicted_at_risk"])
    }

    rationale_bytes =
      JSON.encode!(%{
        "operator" => parts.operator,
        "manifest" => manifest,
        "critic" => parts.critic,
        "sessions" => parts.sessions,
        "evidence" => Map.get(context, :evidence, %{})
      })

    rationale =
      ArtifactReference.from_bytes("proposer_trace", rationale_bytes,
        media_type: "application/json",
        content_schema: "lemieux.proposer-trace/v1",
        scope: plan.scope
      )

    ordinal = Map.fetch!(context, :ordinal)

    id =
      "cand_" <>
        String.pad_leading(Integer.to_string(ordinal), 3, "0") <>
        "_" <> binary_part(content.sha256, 0, 8)

    attrs = %{
      "id" => id,
      "scope" => plan.scope,
      "parents" => [parts.parent_ref],
      "content" => ArtifactReference.to_map(content),
      "proposer" => plan.proposer,
      "rationale" => ArtifactReference.to_map(rationale),
      "interface_validation" => Surface.interface_validation(parts.validation),
      "exposures" => [
        %{"source_case_ids" => exposed_case_ids(plan, Map.get(context, :evaluations, []))}
      ],
      "mutation_kind" => parts.operator,
      "extensions" => %{
        "prediction" => prediction,
        "critic" => parts.critic,
        "hypothesis" => manifest["hypothesis"],
        "targeted_cluster" => manifest["targeted_cluster"],
        "changed_paths" => changed_paths(parts.validation, manifest),
        "sessions" => parts.sessions,
        "proposer_usage" => accounting(parts.usages, parts.started)
      }
    }

    with {:ok, candidate} <- Candidate.new(plan, attrs) do
      retain(context, content.sha256, parts.bytes)
      retain(context, rationale.sha256, rationale_bytes)
      {:ok, candidate, accounting(parts.usages, parts.started)}
    end
  end

  defp changed_paths({:ok, %{"changed_paths" => paths}}, _manifest), do: paths
  defp changed_paths(_validation, manifest), do: ids(manifest["changed_paths"])

  defp retain(context, sha256, bytes) do
    case Map.get(context, :retain) do
      fun when is_function(fun, 2) -> fun.(sha256, bytes)
      _none -> :ok
    end
  end

  defp accounting(usages, started) do
    tokens =
      Enum.reduce(usages, 0, fn usage, total ->
        total + (numeric(usage["input_tokens"]) || 0) + (numeric(usage["output_tokens"]) || 0)
      end)

    costs = Enum.map(usages, &numeric(&1["cost_usd"]))

    %{
      "tokens" => tokens,
      "cost_usd" =>
        if(usages != [] and Enum.all?(costs, &is_number/1), do: Enum.sum(costs), else: nil),
      "time_ms" => System.monotonic_time(:millisecond) - started,
      "requests" => Enum.reduce(usages, 0, &((numeric(&1["requests"]) || 0) + &2))
    }
  end

  defp numeric(value) when is_number(value), do: value
  defp numeric(_value), do: nil

  defp session(context, profile, cwd, prompt) do
    options = [
      provider: resolve(Map.fetch!(context, :provider)),
      sessions_dir: Map.get(context, :sessions_dir),
      timeout_ms: Map.get(context, :timeout_ms, :timer.minutes(10))
    ]

    options = Enum.reject(options, fn {_key, value} -> is_nil(value) end)

    with {:ok, agent_options, _profile} <- Profile.configure(profile, options) do
      input = %{prompt: prompt, cwd: cwd, timeout_ms: Keyword.get(options, :timeout_ms)}

      case AgentSession.run(input, agent_options) do
        {:ok, observation} -> {:ok, observation}
        {:error, _reason, observation} when is_map(observation) -> {:ok, observation}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A zero-arity factory yields a fresh provider per session; a scripted
  # double must not share one consumed script between evolver and critic.
  defp resolve(provider) when is_function(provider, 0), do: provider.()
  defp resolve(provider), do: provider

  defp parent(_plan, context) do
    artifacts = Map.get(context, :artifacts, %{})

    case Map.fetch!(context, :parent) do
      {:seed, %{"id" => id} = seed} ->
        digest = seed["content_sha256"] || seed["sha256"]
        bytes(artifacts, digest, %{"id" => id, "content_sha256" => digest})

      {:candidate, id} ->
        case Enum.find(Map.get(context, :candidates, []), &(&1.id == id)) do
          nil ->
            {:error, {:unknown_parent, id}}

          candidate ->
            digest = Candidate.content_sha256(candidate)
            bytes(artifacts, digest, %{"id" => id, "content_sha256" => digest})
        end
    end
  end

  defp bytes(artifacts, digest, ref) do
    case Map.fetch(artifacts, digest) do
      {:ok, bytes} -> {:ok, ref, bytes}
      :error -> {:error, {:parent_content_missing, digest}}
    end
  end

  defp decode_profile(bytes) do
    case JSON.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :parent_not_json}
    end
  end

  defp exposed_case_ids(plan, evaluations) do
    seen = evaluations |> Enum.map(& &1.case_id) |> MapSet.new()
    Enum.filter(plan.development_case_ids, &MapSet.member?(seen, &1))
  end

  defp outcomes(evaluations, policy) do
    evaluations
    |> Enum.filter(&(&1.split == "development"))
    |> Enum.group_by(& &1.candidate_id)
    |> Map.new(fn {candidate_id, rows} ->
      {candidate_id,
       rows
       |> Enum.group_by(& &1.case_id)
       |> Map.new(fn {case_id, evaluations} ->
         {case_id, Enum.all?(evaluations, &Policy.success?(&1, policy))}
       end)}
    end)
  end

  defp ids(value) when is_list(value),
    do: value |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

  defp ids(_value), do: []

  # At the meta level the document being edited is itself a proposer profile:
  # the cases are inner campaigns and the objectives are the inner proposer's
  # yield and calibration. Saying so is what keeps the evolver from treating a
  # proposer's system prompt as a coding agent's.
  defp level_prefix("meta") do
    "Meta level: the document you are editing is the PROFILE OF A PROPOSER (the agent that " <>
      "proposes harness edits), not a coding agent. Each development case is an inner discovery " <>
      "campaign run with that proposer; its objectives are the inner proposer's frontier yield, " <>
      "prediction calibration (lower Brier is better) and token use. Edit the proposer's " <>
      "instructions so its proposals are better diagnosed, smaller, and better predicted. "
  end

  defp level_prefix(_level), do: ""

  defp task_prompt("reaction_norm") do
    "Operator: reaction_norm. The parent candidate failed several development cases " <>
      "(evidence/operator.json lists them). Find the mechanism those failures share; the " <>
      "defect lies in their intersection. Propose one edit for that shared mechanism."
  end

  defp task_prompt("cross_lineage") do
    "Operator: cross_lineage. For each pair in evidence/operator.json, the parent failed a case " <>
      "that a reference candidate handled differently. Compare the two transcript excerpts, " <>
      "diagnose the behavioral difference, and adapt the successful behavior into the parent's " <>
      "document. Do not copy the reference's text wholesale; express the behavior in the parent's terms."
  end

  defp task_prompt("consolidate") do
    "Operator: consolidate. The parent succeeds on its cases. Reduce the size of the document " <>
      "(system prompt and tool descriptions) without changing behavior: remove redundancy, keep " <>
      "every instruction that a transcript shows mattered. Predict no fixes; list at-risk cases honestly."
  end

  defp task_prompt(_clonal) do
    "Operator: clonal. Read the failure cluster with the most support in evidence/summary.md " <>
      "and the transcript excerpts behind it. Propose one minimal edit that addresses that mechanism."
  end

  defp instructions(plan, operator, evidence) do
    """
    # Proposal workspace

    Operator: #{operator}
    Mutation surface (the only paths you may change): #{Enum.join(Surface.allowed_paths(plan), ", ")}
    Objectives: #{Enum.map_join(plan.objectives, ", ", &"#{&1["name"]} (#{&1["direction"]})")}
    Evidence selected for this proposal: #{JSON.encode!(Map.take(evidence, ~w(operator failed_case_ids pairs)))}

    Write proposal/profile.json and proposal/manifest.json as instructed in the system prompt.
    """
  end

  defp critic_prompt(manifest, workspace) do
    evidence = File.read(Path.join(workspace.root, "evidence/operator.json"))
    summary = File.read(Path.join(workspace.root, "evidence/summary.md"))

    """
    Proposed manifest:
    #{JSON.encode!(manifest)}

    Evidence selected for the proposal:
    #{elem(evidence, 1)}

    Evidence summary:
    #{elem(summary, 1)}

    Answer with JSON only.
    """
  end

  defp parse_verdict(answer) when is_binary(answer) do
    with [json | _] <- Regex.run(~r/\{.*\}/s, answer),
         {:ok, %{"verdict" => verdict} = map} when verdict in ["accept", "veto"] <-
           JSON.decode(json) do
      %{"verdict" => verdict, "reason" => to_string(Map.get(map, "reason", ""))}
    else
      _other -> verdict_from_prose(answer)
    end
  end

  defp parse_verdict(_answer),
    do: %{"verdict" => "unavailable", "reason" => "critic produced no answer"}

  # A critic that answered in prose still answered; only a silent or
  # contradictory one is unavailable.
  defp verdict_from_prose(answer) do
    lowered = String.downcase(answer)
    veto? = String.contains?(lowered, "veto")
    accept? = String.contains?(lowered, "accept")

    cond do
      veto? and not accept? -> %{"verdict" => "veto", "reason" => String.slice(answer, 0, 400)}
      accept? and not veto? -> %{"verdict" => "accept", "reason" => String.slice(answer, 0, 400)}
      true -> %{"verdict" => "unavailable", "reason" => "critic answer was not a verdict"}
    end
  end
end
