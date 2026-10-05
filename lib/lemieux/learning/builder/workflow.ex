defmodule Lemieux.Learning.Builder.Workflow do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  The builder's deterministic workflow, inventory and scaffolding tool.

  Provider state remains a host tool, outside persisted session configuration.
  Generation and evaluation use the ordinary tools and explicit Mix workflow;
  this tool does not spend model budget or expose confirmation data.
  """

  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Builder.Scaffold
  alias Lemieux.Learning.Extension.ModelSearch
  alias Lemieux.Tools.Write

  @derive {Inspect, only: []}
  @enforce_keys [:provider]
  defstruct [:provider]
  @type t :: %__MODULE__{provider: Lemieux.Provider.t()}

  @doc "Binds discovery to the host connection without retaining keys in tool arguments."
  @spec new(provider :: Lemieux.Provider.t()) :: t()
  def new(provider), do: %__MODULE__{provider: provider}

  @doc false
  @spec name(tool :: t()) :: String.t()
  def name(_tool), do: "extension_workflow"

  @doc false
  @spec description(tool :: t()) :: String.t()
  def description(_tool),
    do:
      "Get the extension workflow guide, list models/efforts, validate or save a user selection, or scaffold an extension. No generation or benchmark calls."

  @doc false
  @spec schema(tool :: t()) :: map()
  def schema(_tool) do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["guide", "models", "select_models", "save_models", "plan_models", "scaffold"]
        },
        "case_count" => %{"type" => "integer", "minimum" => 1},
        "repetitions" => %{"type" => "integer", "minimum" => 1},
        "max_attempts" => %{"type" => "integer", "minimum" => 1},
        "max_requests_per_attempt" => %{"type" => "integer", "minimum" => 1},
        "selection_json" => %{
          "type" => "string",
          "description" =>
            "JSON array of {model: provider:id, efforts: [default, ...]} selected by the user."
        },
        "directory" => %{
          "type" => "string",
          "description" => "New directory relative to the current workspace."
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "For save_models: destination relative to the workspace, usually bench/models.json."
        },
        "name" => %{
          "type" => "string",
          "description" => "Lowercase snake_case Mix application name."
        },
        "profile_json" => %{
          "type" => "string",
          "description" =>
            "Required for scaffold, together with directory and name. Complete profile JSON from guide."
        }
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  @doc false
  @spec parallel_safe?(tool :: t()) :: boolean()
  def parallel_safe?(_tool), do: false

  @doc false
  @spec metadata(tool :: t()) :: map()
  def metadata(_tool) do
    %{
      effects: %{class: "write", resource_types: ["extension_source", "file"]},
      runtime: %{concurrency: %{class: "exclusive"}}
    }
  end

  @doc false
  @spec run(tool :: t(), args :: map(), context :: Lemieux.Tool.context()) ::
          {:ok, String.t()} | {:error, term()}
  def run(_tool, %{"action" => "guide"}, _context), do: {:ok, guide()}

  def run(tool, %{"action" => "models"}, _context),
    do: {:ok, JSON.encode!(ModelSearch.inventory(tool.provider))}

  def run(tool, %{"action" => "select_models", "selection_json" => json}, _context) do
    with {:ok, selections} <- JSON.decode(json),
         {:ok, candidates} <- ModelSearch.select(tool.provider, selections),
         do: {:ok, JSON.encode!(candidates)}
  end

  def run(tool, %{"action" => "save_models", "path" => path, "selection_json" => json}, context) do
    # Expanded candidates are runtime records, not the grouped search-file
    # schema. A live builder wrote singular `effort` fields and produced an
    # unusable file. Validate before touching the destination, and serialize
    # the accepted input through the host's ordinary filesystem seam.
    with {:ok, selections} <- JSON.decode(json),
         {:ok, candidates} <- ModelSearch.select(tool.provider, selections),
         {:ok, message} <-
           Write.run(%{"path" => path, "content" => JSON.encode!(selections)}, context) do
      {:ok,
       JSON.encode!(%{
         "message" => message,
         "selections" => selections,
         "candidate_count" => length(candidates)
       })}
    end
  end

  def run(
        _tool,
        %{
          "action" => "scaffold",
          "directory" => directory,
          "name" => name,
          "profile_json" => json
        },
        context
      ) do
    with :ok <- local_environment(context),
         {:ok, relative} <- relative_directory(directory, context.cwd),
         {:ok, profile} <- decode_profile(json),
         :ok <- scaffold_profile(profile),
         {:ok, receipt} <- Scaffold.create(Path.join(context.cwd, relative), name, profile) do
      {:ok, JSON.encode!(receipt)}
    else
      {:error, reason} -> {:error, "Cannot scaffold: #{describe_error(reason)}"}
    end
  end

  def run(_tool, %{"action" => "scaffold"} = args, _context) do
    missing = Enum.reject(~w(directory name profile_json), &Map.has_key?(args, &1))

    {:error,
     "Scaffold requires directory, name and profile_json. Missing: #{Enum.join(missing, ", ")}. Use guide for the complete profile; do not guess or scaffold manually."}
  end

  def run(tool, %{"action" => "plan_models", "selection_json" => json} = args, _context) do
    with {:ok, selections} <- JSON.decode(json),
         {:ok, candidates} <- ModelSearch.select(tool.provider, selections),
         :ok <- plan_bounds(args) do
      attempts = length(candidates) * args["case_count"] * args["repetitions"]

      {:ok,
       JSON.encode!(%{
         "candidate_count" => length(candidates),
         "planned_attempts" => attempts,
         "maximum_direct_requests" => attempts * args["max_requests_per_attempt"],
         "max_attempts" => args["max_attempts"],
         "fits_budget" => attempts <= args["max_attempts"],
         "budget_scope" => "whole comparison; max_attempts is not retries per case",
         "availability" => "configured catalog, not verified entitlement",
         "executed" => false
       })}
    end
  end

  def run(_tool, _args, _context), do: {:error, "Invalid extension workflow action or arguments."}

  defp local_environment(context) do
    if Lemieux.Environment.from_context(context) == Lemieux.Environment.Local,
      do: :ok,
      else: {:error, "requires the local environment"}
  end

  defp relative_directory(directory, cwd) when is_binary(directory) do
    case Path.safe_relative(directory, cwd) do
      {:ok, relative} when relative not in ["", "."] -> {:ok, relative}
      _ -> {:error, "directory must be a new directory inside the workspace"}
    end
  end

  defp relative_directory(_directory, _cwd), do: {:error, "directory must be a string"}

  defp decode_profile(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, profile} -> {:ok, profile}
      _ -> {:error, "profile_json must contain valid JSON"}
    end
  end

  defp decode_profile(_json), do: {:error, "profile_json must be a JSON string"}

  defp scaffold_profile(%{"tools" => tools} = profile) when is_list(tools) do
    unsupported = tools -- Profile.tool_names()

    if unsupported == [],
      do: Profile.validate(profile),
      else:
        {:error,
         "unsupported profile tools: #{inspect(unsupported)}. Supported: #{Enum.join(Profile.tool_names(), ", ")}"}
  end

  defp scaffold_profile(profile), do: Profile.validate(profile)
  defp describe_error(reason) when is_binary(reason), do: reason

  defp describe_error(:invalid_session_profile),
    do: "invalid profile shape or options; use the complete guide schema"

  defp describe_error(:destination_exists),
    do: "destination already exists; inspect and continue it without overwriting"

  defp describe_error(reason), do: inspect(reason)

  defp plan_bounds(args) do
    if Enum.all?(
         ~w(case_count repetitions max_attempts max_requests_per_attempt),
         &(is_integer(args[&1]) and args[&1] > 0)
       ),
       do: :ok,
       else:
         {:error,
          "plan_models requires positive case_count, repetitions, max_attempts and max_requests_per_attempt"}
  end

  @doc "Versioned workflow knowledge carried by the first-party agent in installed releases."
  @spec guide() :: String.t()
  def guide do
    """
    Extension builder workflow v3
    1. Agree on the job, examples, acceptance checks, tools, quality/latency/cost
       constraints and provider/model/effort shortlist. Record these in BUILDING.md.
    2. Use scaffold with all three required fields: directory, name, profile_json.
       Supported portable tools: #{Enum.join(Profile.tool_names(), ", ")}.
       Custom tools are supported through a compiled extension tool_registry/0.
       Scaffold with built-ins first, then implement/register native Lemieux.Tool
       modules and select their names. Never offer unimplemented fetch or other
       proposed tools as already available.
       Complete profile shape:
       {"execution":"live","model":"provider:id","tools":["read","write","edit","bash"],
        "options":{"system":"Task instructions","max_turns":12,"max_tokens":4096,
        "max_cost_usd":1.0,"reasoning_effort":"default","temperature":0.2}}
       No keys, endpoints or credentials. Optionally set LEMIEUX_EXTENSION_BASE in the host
       environment when compiling the generated project, not to create the scaffold.
       A bash export cannot change the host process environment. Read the specific
       error and repair its cause; do not replace the scaffold with guessed source.
       The generated project depends on the lemieux release from Hex.
       For an authorized quota subscription, use options usage_mode="quota",
       max_cost_usd=null and an explicit positive max_requests (for example 12),
       retaining max_turns/max_tokens. Metered profiles omit those extra fields.
       Prefer reusable Elixir modules for deterministic preparation, validation,
       parsing and pipelines. Test these without a model. Expose appropriate steps
       as tools with schemas, effect metadata, bounds and host environment support.
       Generated configure/2 and cli/2 share tool_registry/0 with the workbench.
       Run native extensions via their compiled Mix cli/2; standalone profile JSON
       cannot load new Elixir modules. An extension can declare Hex dependencies
       in mix.exs; resolve/lock them and list mix.lock, lib/ and required assets in
       the export manifest. Keep deps/_build out. Record external executables,
       application startup/configuration and other consumer prerequisites.
    3. Edit development inputs, task prompts and the deliberately failing grader.
       Graders consume {answer}/{cwd}; they must check the desired behavior.
       Keep workbench storage outside case workspaces. Keep hidden tests outside
       the builder's workspace and tool authority, managed by a separate host.
    4. Use models and select_models for the configured connection's inventory and
       the user's shortlist. Catalog availability is not account entitlement.
       Use save_models with path="bench/models.json" and selection_json containing
       [{"model":"provider:id","efforts":["default"]}]. It validates and saves the
       grouped search-file schema. Do not write expanded candidates or singular
       effort fields into that file. select_models is still read-only; its output
       is for inspection, not file serialization. Different models support
       different effort values.
    5. In the generated Mix project, set explicit benchmark caps in bench/workbench.exs.
       `mix lemieux.extension.compare bench/workbench.exs bench/models.json` plans.
       Add --allow-live after the developer has authorized that live comparison;
       existing authorization includes quota subscriptions, not just dollar spend.
       Reports in tmp/workbench/runs preserve failures and unknown cost as unknown.
       Quota workbenches use usage_mode: :quota, max_attempts and
       max_requests_per_attempt in benchmark_options instead of USD caps.
       Use plan_models with selection_json, case_count, repetitions, max_attempts
       and max_requests_per_attempt before quoting counts or a quota ceiling.
       Attempts = cases × expanded model/effort candidates × repetitions.
       max_attempts caps the WHOLE comparison, not retries per case. If fits_budget
       is false, reduce the selection or agree a larger total before running.
       Builder session limits are separate; these settings do not reconfigure it.
       Compare the same cases/repetitions. Review regressions and resource tradeoffs;
       this is development selection, not a general best-model claim.
    6. Save a hypothesis, inspect development failures, change one surface, rerun.
       Track cumulative authoring and evaluation usage across retries and restarts.
       In quota mode count direct requests and attempts, retaining unknown dollars
       and remaining provider quota as unknown. Local requests are not quota units.
       Copy the chosen model, effort and instructions into priv/profile.json and
       recompile. CLI --extension-profile and the agent use the same settings.
    7. `mix lemieux.extension.freeze bench/freeze.exs NEW_DIRECTORY` freezes source,
       profile and runtime. Independently prepare confirmation with
       Lemieux.Learning.Extension.Confirmation.prepare/6 (control/candidate builds, Corpus,
       predeclared experiment and evaluator_root). Carry workbench exposure using
       Workbench.expose_corpus/2; the host must persist that returned corpus.
       Quota confirmation uses usage_mode="quota", maximum_requests and
       max_requests_per_attempt in extension_policy, plus repetitions, latency
       limit and unknown_cost="allow". Its plan budget has usage_mode="quota"
       and matching maximum_requests. Reserve enough for every attempt times its
       request bound. This is a local request allowance, not provider quota units.
       `mix lemieux.extension.confirm prepare CONFIG.exs NEW_DIRECTORY`, then
       `run DIRECTORY EXPECTED_SHA256 --allow-live`. Confirmation is single-use,
       even when interrupted. Persist Confirmation.exposure/1 in the host ledger.
    8. The independent host exports only a passing candidate with
       `mix lemieux.extension.confirm export DIRECTORY EXPECTED_SHA256 NEW_PACKAGE`.
       Keep the confirmation sidecar separate; ordinary Extension.export/2 stays
       unassessed. Install the Mix dependency only when authorized; preserve the
       qualified profile/runtime and repeat smoke/regression in the consumer host.
    Do not give the builder holdouts; local tools are not a sandbox. It must not
    approve itself or claim efficacy from scripted tests. First-party candidates
    follow the same checks as others.
    """
  end
end
