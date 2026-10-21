defmodule Lemieux.CLI.Learning.AssetSearch do
  @moduledoc """
  Explicit research search over reviewed procedure trees, inert helper source,
  and allowlisted shipped settings. This host lane never loads generated code
  into the VM or installs an asset persistently. A separately metered critic
  reviews each exact digest before fresh isolated probes can read its files.
  Helpers can be used only through the task's ordinary confined tools.

  The caller supplies current isolation, public evidence and an execution
  callback that assembles the ordinary CLI in a new lease. Private grading
  never enters proposal, review, probe selection or this receipt. Unknown or
  incomplete evidence refuses selection; repeated verified ties are explicitly
  experimental search choices, not efficacy claims.
  """
  alias Lemieux.Agent.Session
  alias Lemieux.Asset.Version
  alias Lemieux.CLI.Learning.Reflection
  alias Lemieux.Contract
  alias Lemieux.Evidence.Run
  alias Lemieux.Extension.Profile
  alias Lemieux.Extensions.Workspace.AssetReader
  alias Lemieux.Extensions.Workspace.AssetReader.Local, as: LocalReader
  alias Lemieux.Harness
  alias Lemieux.Harness.Snapshot
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Asset.Extension
  alias Lemieux.Learning.Controller
  alias Lemieux.Learning.Refinement
  alias Lemieux.Learning.Refinement.Evidence
  alias Lemieux.Learning.Refinement.Support
  alias Lemieux.RequestSnapshot

  @system """
  You are Lemieux's typed asset proposer. Use the public task trajectory and
  authorized earlier experience to propose reusable harness components. Return
  JSON only: {"assets":[ASSET,...]}. At most two assets: one skill/procedure tree
  and one shipped configuration. Return {"assets":[]} if no concrete hypothesis is justified.
  Each ASSET has exactly kind, payload, files, requires_tools, triggers.
  A skill has kind "skill", payload {"name":"lowercase-hyphenated-name"},
  with no other payload keys. Description belongs only in SKILL.md frontmatter.
  files {"SKILL.md":"---\\nname: ...\\ndescription: Use when ...\\n---\\n...",
  "helpers/example.py":"optional complete helper source"}, requires_tools as
  available tool names, and descriptive triggers present in its description.
  Include every referenced file. Text files may be .md, .txt or .json; Python
  source is allowed only under helpers/ when the host explicitly lists .py.
  Helpers should implement general workflow utilities, never the current task's
  solution, expected outputs, a task-specific algorithm or a grader shortcut.
  No dependency installation, credentials, network access or permission changes.
  Files remain inert and are read on demand; no module can be selected or loaded.
  A configuration has kind "configuration", payload {"extension":"search",
  "glob_after_requests":0..4}, files {}, triggers [], requires_tools ["glob"].
  It changes only discovery of an already available tool. Do not invent settings.
  All assets are unconfirmed hypotheses. Cite the observed workflow in the skill
  body and describe conditions and uncertainty. Never refer to benchmark cases,
  hidden verification, task IDs or grant yourself authority.
  """
  @critic """
  You review an unconfirmed harness asset against its public source evidence.
  Read all of its files. Reject task solutions, expected outputs, hidden-test
  references, unrelated speculative changes, missing dependencies, unsafe helper
  behavior, credential/network/permission requests, and unsupported mechanisms.
  Approve only a bounded reusable workflow hypothesis within the host allowlist.
  Approval is permission for an isolated experiment, never correctness or transfer.
  Return JSON only: {"asset_sha256":"the supplied exact digest",
  "decision":"approve"|"reject","reason":"specific source-backed reason"}.
  """

  @spec protocol() :: map()
  def protocol,
    do: %{
      "id" => "reviewed_assets/v2",
      "maximum_candidates" => 2,
      "repetitions" => 2,
      "kinds" => ["skill", "configuration"],
      "helper_extensions" => [".py"],
      "structural_repair" => "at_most_one_toolless_format_repair_no_probe_feedback",
      "activation" => "isolated_task_only_exact_digest_review"
    }

  @spec run(record :: map(), context :: map(), opts :: keyword()) ::
          {:ok, map(), [map()]} | {:error, term()}
  def run(record, context, opts) do
    plan = %{
      "schema_version" => 1,
      "kind" => "experimental_asset_plan",
      "protocol" => protocol(),
      "source_sha256" => Contract.digest(record),
      "context" =>
        Map.take(context, [
          :scope,
          :binding,
          :trust,
          :tools,
          :description_tools,
          :settings_allowlist,
          :helper_extensions
        ])
        |> Contract.json(),
      "bindings" => opts[:bindings],
      "model" => opts[:editor_model],
      "effort" => opts[:editor_effort],
      "support_policy" => opts[:support_policy],
      "allocation" => Contract.json(opts[:allocation])
    }

    allocation = opts[:allocation] || %{requests: 0, tokens: 0, time_ms: 0}

    plan =
      Map.put(plan, "budget", %{
        "maximum_requests" => allocation.requests,
        "maximum_tokens" => allocation.tokens,
        "maximum_time_ms" => allocation.time_ms,
        "usage_mode" => "quota",
        "maximum_candidates" => 2
      })

    plan = Map.put(plan, "sha256", Contract.digest(plan))

    with :ok <- Refinement.preflight(opts[:isolation], opts[:bindings]),
         :ok <- Support.verify(opts[:support_policy]),
         :ok <- opts[:intent].(plan),
         true <-
           opts[:allow_live] == true or Controller.scripted?(opts[:provider].(:asset_proposer)),
         {:ok, {:ok, receipt, selected}, accounting} <-
           Controller.experiment(
             opts[:controller],
             "typed-assets",
             plan,
             opts[:allocation],
             fn child ->
               lane(record, context, Keyword.put(opts, :controller, child))
             end
           ) do
      receipt = receipt |> Map.put("plan", plan) |> Map.put("accounting", accounting)
      {:ok, Map.put(receipt, "sha256", Contract.digest(receipt)), selected}
    else
      failure -> {:error, {:asset_search_incomplete, failure_name(failure)}}
    end
  end

  defp lane(record, context, opts) do
    with {:ok, attrs, proposal} <- propose(record, context, opts),
         {:ok, reviewed, reviews} <- review(attrs, record, context, opts),
         {:ok, control} <- probes([], opts),
         {:ok, candidates} <- candidates(reviewed, opts) do
      supported =
        Enum.filter(
          candidates,
          &Support.supported?(control, &1.evaluations, true, opts[:support_policy])
        )

      selected = Enum.map(supported, & &1.item)
      select_composition(selected, control, candidates, proposal, reviews, opts)
    end
  end

  defp select_composition(selected, control, candidates, proposal, reviews, opts) do
    with {:ok, composed} <- composition(selected, opts) do
      selected =
        if selected != [] and Support.supported?(control, composed, true, opts[:support_policy]),
          do: selected,
          else: []

      receipt = %{
        "schema_version" => 1,
        "kind" => "experimental_asset_search",
        "decision" => if(selected == [], do: "baseline", else: "selected"),
        "qualification" => "experimental_task_local",
        "proposal" => proposal,
        "reviews" => reviews,
        "control" => control,
        "candidates" =>
          Enum.map(
            candidates,
            &%{
              "asset" => wire(&1.item.version),
              "review" => &1.item.review,
              "evaluations" => &1.evaluations
            }
          ),
        "composition" => composed,
        "selected_asset_sha256" => Enum.map(selected, & &1.version.digest)
      }

      {:ok, receipt, selected}
    end
  end

  defp propose(record, context, opts) do
    prompt =
      JSON.encode!(%{
        "public_record" => record,
        "available_tools" => context.tools,
        "settings_allowlist" => context.settings_allowlist,
        "helper_extensions" => context[:helper_extensions] || []
      })

    with {:ok, observation} <- session(@system, prompt, :proposer, :asset_proposer, opts) do
      case validate_answer(observation["answer"], context, opts) do
        {:ok, attrs} -> {:ok, attrs, model_observation(observation)}
        {:error, reason} -> repair(observation, reason, context, opts)
      end
    end
  end

  defp repair(original, reason, context, opts) do
    prompt =
      JSON.encode!(%{
        "format_repair_only" => true,
        "original_answer" => original["answer"],
        "validation_error" => reason,
        "instructions" =>
          "Preserve the original hypotheses and components; correct only schema/loader formatting. Do not invent improvements, helpers or settings. Return exactly {\"assets\":[...]}. Each asset has only kind,payload,files,requires_tools,triggers. A skill payload has ONLY name; put description only in SKILL.md frontmatter. Each trigger must be an exact literal substring of that description. Include all referenced files. No probe feedback or quality retry is available.",
        "available_tools" => context.tools,
        "settings_allowlist" => context.settings_allowlist,
        "helper_extensions" => context[:helper_extensions] || []
      })

    with {:ok, repaired} <- session(@system, prompt, :proposer, :asset_proposer, opts) do
      receipt =
        model_observation(repaired)
        |> Map.put("structural_repair", %{
          "reason" => reason,
          "original" => model_observation(original)
        })

      case validate_answer(repaired["answer"], context, opts) do
        {:ok, attrs} -> {:ok, attrs, receipt}
        {:error, error} -> {:ok, [], Map.put(receipt, "rejected", error)}
      end
    end
  end

  defp validate_answer(answer, context, opts) do
    case JSON.decode(answer || "") do
      {:ok, %{"assets" => attrs} = result}
      when map_size(result) == 1 and is_list(attrs) and length(attrs) <= 2 ->
        validate_trees(attrs, context, opts)

      _invalid ->
        {:error, "invalid_proposal_schema"}
    end
  end

  defp validate_trees(attrs, context, opts) do
    if Enum.all?(attrs, &valid_tree?(&1, context, opts)),
      do: {:ok, attrs},
      else: {:error, "invalid_asset_schema_or_literal_trigger_or_complete_loader_tree"}
  end

  defp valid_tree?(attrs, context, opts) do
    root = Path.join(opts[:cwd], "validate-" <> Lemieux.ID.generate())

    try do
      with true <- search_surface?(attrs),
           {:ok, version} <- Asset.new(attrs, context),
           {:ok, _} <- Asset.materialize(version, root, context),
           do: true,
           else: (_invalid -> false)
    after
      File.rm_rf!(root)
    end
  end

  defp review(attrs, record, context, opts) do
    Enum.reduce_while(attrs, {:ok, [], []}, fn attrs, {:ok, accepted, receipts} ->
      kind = if is_map(attrs), do: attrs["kind"]

      case review_candidate(attrs, receipts, record, context, opts) do
        {:ok, item, receipt} ->
          {:cont,
           {:ok, accepted ++ List.wrap(item),
            receipts ++ [Map.put(receipt, "submitted_kind", kind)]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp review_candidate(attrs, receipts, record, context, opts) do
    kind = if is_map(attrs), do: attrs["kind"]

    if Enum.any?(receipts, &(&1["submitted_kind"] == kind)),
      do: {:ok, nil, rejected(attrs, "duplicate_asset_kind")},
      else: review_one(attrs, record, context, opts)
  end

  defp review_one(attrs, record, context, opts) do
    with true <- search_surface?(attrs),
         {:ok, version} <- Asset.new(attrs, context),
         {:ok, _skill} <- Asset.materialize(version, Path.join(opts[:cwd], version.id), context) do
      review_model(version, attrs, record, opts)
    else
      _invalid -> {:ok, nil, rejected(attrs, "asset_validation_rejected")}
    end
  end

  defp review_model(version, attrs, record, opts) do
    prompt =
      JSON.encode!(%{
        "public_record" => record,
        "asset_sha256" => version.digest,
        "asset" => attrs
      })

    with {:ok, observation} <- session(@critic, prompt, :critic, :asset_critic, opts) do
      receipt = review_response(observation, version)

      approve_review(version, receipt, opts)
    end
  end

  defp approve_review(version, %{"decision" => "approve"} = receipt, opts) do
    with :ok <- opts[:approve].(version, receipt),
         do: {:ok, %{version: version, review: receipt}, receipt}
  end

  defp approve_review(_version, receipt, _opts), do: {:ok, nil, receipt}

  defp review_response(observation, version) do
    base = %{
      "asset_sha256" => version.digest,
      "decision" => "reject",
      "reason" => "invalid_critic_response",
      "observation" => model_observation(observation)
    }

    case JSON.decode(observation["answer"] || "") do
      {:ok, %{"asset_sha256" => sha, "decision" => decision, "reason" => reason} = response}
      when map_size(response) == 3 and sha == version.digest and decision in ~w(approve reject) and
             is_binary(reason) and byte_size(reason) in 1..2048 ->
        Map.merge(base, response)

      _invalid ->
        base
    end
  end

  defp rejected(attrs, reason),
    do: %{
      "proposal_sha256" => Contract.digest(%{"asset" => attrs}),
      "decision" => "reject",
      "reason" => reason
    }

  defp search_surface?(%{"kind" => "skill"}), do: true

  defp search_surface?(%{
         "kind" => "configuration",
         "payload" => %{"glob_after_requests" => count}
       }),
       do: count in 0..4

  defp search_surface?(_attrs), do: false

  defp candidates(reviewed, opts) do
    Enum.reduce_while(reviewed, {:ok, []}, fn item, {:ok, results} ->
      case probes([item], opts) do
        {:ok, evaluations} -> {:cont, {:ok, results ++ [%{item: item, evaluations: evaluations}]}}
        error -> {:halt, error}
      end
    end)
  end

  defp composition([], _opts), do: {:ok, []}
  defp composition(selected, opts), do: probes(selected, opts)

  defp probes(assets, opts) do
    Enum.reduce_while(1..2, {:ok, []}, fn _, {:ok, results} ->
      with :ok <- Refinement.preflight(opts[:isolation], opts[:bindings]),
           {:ok, attempt} <- opts[:probe].(assets, opts[:controller]),
           {:ok, evidence} <-
             evidence(attempt, Enum.map(assets, & &1.version.digest), opts[:task_model]) do
        {:cont, {:ok, results ++ [evidence]}}
      else
        _invalid -> {:halt, {:error, :asset_probe_incomplete}}
      end
    end)
  end

  defp session(system, prompt, role, provider_role, opts) do
    provider =
      Controller.provider(opts[:controller], role, opts[:provider].(provider_role),
        token_bound: opts[:token_bound],
        timeout_ms: 180_000
      )

    profile =
      Profile.quota(
        %{
          "execution" => "live",
          "model" => opts[:editor_model],
          "tools" => [],
          "options" => %{
            "system" => system,
            "max_turns" => 1,
            "max_tokens" => 16_384,
            "max_cost_usd" => nil,
            "reasoning_effort" => opts[:editor_effort],
            "temperature" => 0.0
          }
        },
        1
      )

    with {:ok, configured, _} <-
           Profile.configure(profile,
             provider: provider,
             sessions_dir: opts[:sessions_dir],
             supervisor: opts[:supervisor]
           ) do
      Session.run(%{prompt: prompt, cwd: opts[:cwd], timeout_ms: 480_000}, configured)
    end
  end

  @doc "Assembles only independently reviewed digests through the actual asset extension."
  @spec apply(
          assets :: [map()],
          base :: Harness.t(),
          context :: map(),
          root :: Path.t(),
          environment :: term()
        ) :: {:ok, Harness.t()} | {:error, term()}
  def apply(assets, base, context, root, environment) do
    specifications =
      Enum.map(assets, fn item ->
        asset_root = Path.join(root, item.version.id)

        reader = fn
          ^environment ->
            {:ok,
             AssetReader.new({LocalReader, nil},
               roots: [asset_root],
               home: Path.join(asset_root, "unused-home")
             )}

          _changed ->
            {:error, :environment_changed}
        end

        {Extension,
         [
           version: item.version,
           root: asset_root,
           context: Map.put(context, :asset_reader, reader)
         ]}
      end)

    with true <-
           Enum.all?(
             assets,
             &(&1.version.digest in context.approved_digests and
                 &1.review["decision"] == "approve" and
                 &1.review["asset_sha256"] == &1.version.digest)
           ),
         {:ok, harness} <- Harness.assemble(base, specifications) do
      {:ok, harness}
    else
      _unreviewed -> {:error, :asset_not_reviewed}
    end
  end

  @doc "Checks terminal manifests, request snapshots, exact asset identities and known usage."
  @spec evidence(attempt :: map(), assets :: [String.t()], model :: String.t()) ::
          {:ok, map()} | {:error, term()}
  def evidence(%{observation: observation, grade: grade}, assets, model) do
    entries = observation["transcript"] || []
    terminal = Enum.find(Enum.reverse(entries), &(&1["type"] == "run_evidence"))

    with %{"payload" => run} <- terminal,
         :ok <- Run.verify_transcript(run, entries),
         true <- get_in(run, ["usage", "state"]) == "complete",
         true <- get_in(run, ["completeness", "artifacts"]) == "complete",
         true <- request_assets?(entries, run, assets, model),
         score when is_number(score) and score >= 0 and score <= 1 <- grade["score"],
         {:ok, assessment} <-
           Evidence.terminal(observation, run, %{
             "score" => score,
             "regression" => not grade["passed"],
             "verified_success" => grade["passed"],
             "safety_failure" => grade["safety_failures"] != []
           }) do
      {:ok,
       %{
         "score" => assessment["score"],
         "regression" => assessment["regression"],
         "verified_success" => assessment["verified_success"],
         "safety_failure" => assessment["safety_failure"],
         "evidence_complete" => true,
         "observation" => Reflection.project(observation),
         "observation_sha256" => Contract.digest(observation)
       }}
    else
      _invalid -> {:error, :invalid_asset_probe_evidence}
    end
  end

  defp request_assets?(entries, run, assets, model) do
    snapshots = Enum.filter(entries, &(&1["type"] == "harness_snapshot"))
    requests = Enum.filter(entries, &(&1["type"] == "request"))

    snapshots != [] and requests != [] and
      Enum.all?(snapshots, fn entry ->
        snapshot = entry["payload"]

        Snapshot.verify(snapshot) == :ok and snapshot["model"] == model and
          Enum.sort(Enum.map(snapshot["resolved_assets"], & &1["sha256"])) == Enum.sort(assets)
      end) and Enum.all?(requests, &(RequestSnapshot.verify(&1["payload"]) == :ok)) and
      references?(requests, snapshots, run)
  end

  defp references?(requests, snapshots, run) do
    by_id = Map.new(requests, &{&1["payload"]["id"], &1["payload"]})
    snapshot_ids = Map.new(snapshots, &{&1["payload"]["id"], &1["payload"]["semantic_sha256"]})

    length(run["requests"]) == length(requests) and
      Enum.all?(run["requests"], fn ref ->
        request = by_id[ref["id"]] || %{}

        request["sha256"] == ref["sha256"] and
          snapshot_ids[request["harness_snapshot_id"]] == ref["harness_snapshot_sha256"] and
          request["harness_snapshot_sha256"] == ref["harness_snapshot_sha256"]
      end) and
      snapshot_ids[run["harness_snapshot"]["id"]] == run["harness_snapshot"]["semantic_sha256"]
  end

  defp model_observation(observation),
    do:
      observation
      |> Map.take(~w(session_id answer usage status finish_reason provider_error))
      |> Map.put("source_observation_sha256", Contract.digest(observation))

  defp wire(%Version{} = version),
    do: %{"id" => version.id, "sha256" => version.digest, "content" => version.content}

  defp failure_name({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_name({:skip, receipt}), do: receipt["reason"]
  defp failure_name(_failure), do: "incomplete_or_unknown_execution"
end
