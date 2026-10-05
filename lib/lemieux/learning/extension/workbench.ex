defmodule Lemieux.Learning.Extension.Workbench do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Local development of agent extensions using the paired benchmark runner.

  `open/2` accepts the same trusted configuration as `mix lemieux.extension.eval`,
  plus `:workbench_dir` and `:execution` (`:live` by default, or `:scripted`).
  The mode is the host's declaration, not a sandbox or network restriction.
  Configuration and agent modules are executable code; opening a configuration
  is a separate trust decision from approving its later model calls.

  Cases, named overrides and selections live in `project.json`, separately from
  extension source. Callable options, provider processes and runtime credential
  options are never serialized. Cases and grader commands are saved as authored;
  keep secrets out of those definitions. Run plans record development exposure and requested tuning,
  not frozen builds or proof of effective model settings. Authors may deliberately
  constrain options (for example, the review example owns its system prompt).

  Live runs require `allow_live: true`, a benchmark `:cost_cap_usd` and a
  `:max_cost_per_attempt_usd` reservation. The latter also tightens each ordinary
  session's `:max_cost_usd`. Multi-session extensions still own their cumulative
  budget, deadline and inclusive usage; arbitrary Elixir cannot be contained by
  these options. Reports retain the agent's usage and stages, including unknowns.
  No variant is automatically selected, qualified or installed.
  """

  alias Lemieux.Benchmark
  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Task
  alias Lemieux.Learning.Extension.Workbench.Project

  @type t :: %__MODULE__{
          root: Path.t(),
          base_dir: Path.t(),
          registry: map(),
          project: map(),
          execution: :live | :scripted,
          benchmark_options: keyword()
        }
  @enforce_keys [:root, :base_dir, :registry, :project, :execution, :benchmark_options]
  defstruct [:root, :base_dir, :registry, :project, :execution, :benchmark_options]

  @doc "Opens or creates a local workbench; does not invoke agent option factories."
  @spec open(config :: keyword(), base_dir :: Path.t()) :: {:ok, t()} | {:error, term()}
  def open(config, base_dir \\ File.cwd!()) do
    with :ok <- configuration(config),
         {:ok, registry} <- registry(config[:agents]),
         root =
           Path.expand(Keyword.get(config, :workbench_dir, "tmp/extension-workbench"), base_dir),
         {:ok, project} <- read_or_create(root, config, base_dir, registry),
         :ok <- Project.validate(project, registry, base_dir) do
      state = %__MODULE__{
        root: root,
        base_dir: Path.expand(base_dir),
        registry: registry,
        project: project,
        execution: Keyword.get(config, :execution, :live),
        benchmark_options: Keyword.get(config, :benchmark_options, [])
      }

      persist(state)
    end
  end

  @doc "Adds or replaces a development case without editing the source suite."
  @spec put_case(state :: t(), definition :: map()) :: {:ok, t()} | {:error, term()}
  def put_case(state, definition) do
    with {:ok, task} <- Task.from_map(definition, state.base_dir) do
      tasks = state.project["suite"]["tasks"]
      updated = Enum.reject(tasks, &(&1["id"] == task.id)) ++ [Project.task(task)]
      persist(%{state | project: put_in(state.project, ["suite", "tasks"], updated)})
    end
  end

  @doc "Adds or replaces a named variant based on a trusted configured agent."
  @spec put_variant(state :: t(), name :: String.t(), base :: String.t(), overrides :: map()) ::
          {:ok, t()} | {:error, term()}
  def put_variant(state, name, base, overrides) do
    variant = %{"base" => base, "overrides" => overrides}

    with :ok <- Project.variant(name, variant, state.registry) do
      persist(%{state | project: put_in(state.project, ["variants", name], variant)})
    end
  end

  @doc "Adds a validated set of variants atomically; existing names cannot be replaced."
  @spec add_variants(state :: t(), variants :: map()) :: {:ok, t()} | {:error, term()}
  def add_variants(state, variants) when is_map(variants) and map_size(variants) > 0 do
    existing = state.project["variants"]

    if Enum.any?(Map.keys(variants), &Map.has_key?(existing, &1)) do
      {:error, :variant_already_exists}
    else
      persist(%{
        state
        | project: Map.put(state.project, "variants", Map.merge(existing, variants))
      })
    end
  end

  @doc "Selects the cases and variants for the next comparison, in pairing order."
  @spec select(state :: t(), cases :: [String.t()], variants :: [String.t()]) ::
          {:ok, t()} | {:error, term()}
  def select(state, cases, variants) do
    project =
      state.project |> Map.put("selected_cases", cases) |> Map.put("selected_variants", variants)

    persist(%{state | project: project})
  end

  @doc "Describes the next comparison without constructing providers or invoking agents."
  @spec plan(state :: t()) :: map()
  def plan(state) do
    %{
      "version" => 1,
      "exposure" => "development",
      "qualification" => "unassessed",
      "execution" => to_string(state.execution),
      "project" => state.project,
      "modules" =>
        Map.new(state.project["selected_variants"], fn name ->
          {module, _options} = Map.fetch!(state.registry, state.project["variants"][name]["base"])
          {name, inspect(module)}
        end),
      "planned_attempts" =>
        length(state.project["selected_cases"]) * length(state.project["selected_variants"]) *
          Keyword.get(state.benchmark_options, :repetitions, 1),
      "repetitions" => Keyword.get(state.benchmark_options, :repetitions, 1),
      "cost_cap_usd" => state.benchmark_options[:cost_cap_usd],
      "usage_mode" => to_string(Keyword.get(state.benchmark_options, :usage_mode, :metered)),
      "max_attempts" => state.benchmark_options[:max_attempts],
      "max_requests_per_attempt" => state.benchmark_options[:max_requests_per_attempt],
      "max_cost_per_attempt_usd" => state.benchmark_options[:max_cost_per_attempt_usd]
    }
  end

  @doc "Runs selected variants in copied workspaces and saves a plan and full report."
  @spec run(state :: t(), opts :: keyword()) :: {:ok, map(), String.t()} | {:error, term()}
  def run(state, opts \\ []) do
    with :ok <- authorize(state, opts),
         :ok <- Project.validate(state.project, state.registry, state.base_dir),
         :ok <- separate_storage(state),
         {:ok, manifest} <- selected_manifest(state),
         id = Lemieux.ID.generate(),
         directory = Path.join([state.root, "runs", id]),
         :ok <- write_json(Path.join(directory, "plan.json"), plan(state)),
         {:ok, report} <-
           Benchmark.run(manifest, runtimes(state), run_options(state, directory, opts)) do
      {:ok, report, id}
    end
  end

  @doc "Lists saved runs newest first, including interrupted runs with only a plan."
  @spec history(state :: t()) :: {:ok, [String.t()]} | {:error, term()}
  def history(state) do
    case File.ls(Path.join(state.root, "runs")) do
      {:ok, names} -> {:ok, names |> Enum.filter(&Project.name?/1) |> Enum.sort(:desc)}
      {:error, :enoent} -> {:ok, []}
      error -> error
    end
  end

  @doc "Reads one completed run; an interrupted run returns a file error."
  @spec report(state :: t(), id :: String.t()) :: {:ok, map()} | {:error, term()}
  def report(state, id) do
    if Project.name?(id),
      do: read_json(Path.join([state.root, "runs", id, "report.json"])),
      else: {:error, :invalid_run_id}
  end

  @doc "Carries all current and saved-run case IDs into the host corpus exposure ledger."
  @spec expose_corpus(state :: t(), corpus :: Corpus.t()) :: {:ok, Corpus.t()} | {:error, term()}
  def expose_corpus(state, corpus) do
    with {:ok, ids} <- history(state),
         {:ok, cases} <- exposed_cases(state, ids) do
      Corpus.expose(corpus, Enum.uniq(cases), %{
        consumer_role: "extension_workbench",
        consumer_id: state.root
      })
    end
  end

  defp exposed_cases(state, ids) do
    initial = Enum.map(state.project["suite"]["tasks"], & &1["id"])

    Enum.reduce_while(ids, {:ok, initial}, fn id, {:ok, cases} ->
      case read_json(Path.join([state.root, "runs", id, "plan.json"])) do
        {:ok, %{"project" => %{"suite" => %{"tasks" => tasks}}}} ->
          {:cont, {:ok, Enum.map(tasks, & &1["id"]) ++ cases}}

        _other ->
          {:halt, {:error, {:unreadable_exposure_plan, id}}}
      end
    end)
  end

  defp configuration(config) do
    if Keyword.keyword?(config) and is_binary(config[:suite]) and
         Keyword.get(config, :execution, :live) in [:live, :scripted] and
         is_binary(Keyword.get(config, :workbench_dir, "tmp/extension-workbench")) and
         benchmark_options?(Keyword.get(config, :benchmark_options, [])),
       do: :ok,
       else: {:error, :invalid_workbench_config}
  end

  defp benchmark_options?(options) do
    Keyword.keyword?(options) and positive_integer?(Keyword.get(options, :repetitions, 1)) and
      positive_integer?(Keyword.get(options, :max_concurrency, 1)) and
      Keyword.get(options, :usage_mode, :metered) in [:metered, :quota]
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp registry(agents) when is_list(agents) and agents != [] do
    Enum.reduce_while(agents, {:ok, %{}}, fn
      {name, module, options}, {:ok, acc} when is_atom(module) ->
        if Project.name?(name) and not Map.has_key?(acc, name) and
             (is_function(options, 0) or Keyword.keyword?(options)) do
          {:cont, {:ok, Map.put(acc, name, {module, options})}}
        else
          {:halt, {:error, :invalid_agents}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_agents}}
    end)
  end

  defp registry(_agents), do: {:error, :invalid_agents}

  defp read_or_create(root, config, base_dir, registry) do
    case read_json(Path.join(root, "project.json")) do
      {:error, :enoent} ->
        with {:ok, manifest} <- Manifest.read(Path.expand(config[:suite], base_dir)) do
          {:ok, Project.new(manifest, Enum.map(config[:agents], &elem(&1, 0)))}
        end

      {:ok, project} ->
        with :ok <- Project.validate(project, registry, base_dir), do: {:ok, project}

      error ->
        error
    end
  end

  defp persist(state) do
    with :ok <- Project.validate(state.project, state.registry, state.base_dir),
         :ok <- separate_storage(state),
         :ok <- write_json(Path.join(state.root, "project.json"), state.project),
         do: {:ok, state}
  end

  # Copying a source workspace that contains the workbench would expose previous
  # answers and graders to later attempts, and grow every subsequent copy.
  defp separate_storage(state) do
    nested? =
      Enum.any?(state.project["suite"]["tasks"], fn task ->
        cwd = Path.expand(task["cwd"], state.base_dir)
        state.root == cwd or String.starts_with?(state.root, cwd <> "/")
      end)

    if nested?, do: {:error, :workbench_directory_inside_task_workspace}, else: :ok
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path), do: JSON.decode(body)
  end

  defp write_json(path, data) do
    temporary = path <> "." <> Lemieux.ID.generate() <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, [JSON.encode!(data), ?\n]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  defp authorize(%{execution: :scripted} = state, _opts) do
    if state.benchmark_options[:usage_mode] == :quota, do: quota_budget(state), else: :ok
  end

  defp authorize(state, opts) do
    cap = state.benchmark_options[:cost_cap_usd]
    reservation = state.benchmark_options[:max_cost_per_attempt_usd]

    cond do
      opts[:allow_live] != true ->
        {:error, :live_confirmation_required}

      state.benchmark_options[:usage_mode] == :quota ->
        quota_budget(state)

      not (is_number(cap) and cap > 0 and is_number(reservation) and reservation > 0 and
               reservation <= cap) ->
        {:error, :live_budget_required}

      true ->
        :ok
    end
  end

  defp quota_budget(state) do
    options = state.benchmark_options

    valid =
      positive_integer?(options[:max_attempts]) and
        positive_integer?(options[:max_requests_per_attempt]) and
        plan(state)["planned_attempts"] <= options[:max_attempts] and
        options[:cost_cap_usd] == nil and options[:max_cost_per_attempt_usd] == nil

    if valid, do: :ok, else: {:error, :quota_bounds_required}
  end

  defp selected_manifest(state) do
    tasks = Map.new(state.project["suite"]["tasks"], &{&1["id"], &1})

    suite = %{
      "version" => 1,
      "tasks" => Enum.map(state.project["selected_cases"], &Map.fetch!(tasks, &1)),
      "metadata" => %{"exposure" => "development", "qualification" => "unassessed"}
    }

    Manifest.from_map(suite, state.base_dir)
  end

  defp runtimes(state) do
    Enum.map(state.project["selected_variants"], fn name ->
      variant = state.project["variants"][name]
      {module, options} = Map.fetch!(state.registry, variant["base"])

      factory =
        options_factory(
          options,
          variant["overrides"],
          state.benchmark_options
        )

      Runtime.new(name, Lemieux.Benchmark.Runtime.Agent, agent: module, agent_options: factory)
    end)
  end

  defp options_factory(options, overrides, limits) do
    fn ->
      original = if is_function(options, 0), do: options.(), else: options

      original
      |> tune(overrides)
      |> cap_session(limits[:max_cost_per_attempt_usd])
      |> cap_requests(limits)
    end
  end

  defp cap_requests(options, limits) do
    if limits[:usage_mode] == :quota do
      maximum = limits[:max_requests_per_attempt]
      existing = get_in(options, [:session_options, :max_requests])

      maximum =
        if is_integer(existing) and existing > 0, do: min(existing, maximum), else: maximum

      nested(options, :session_options, :max_requests, maximum)
    else
      options
    end
  end

  defp tune(options, overrides) do
    Enum.reduce(overrides, options, fn
      {"system", value}, acc ->
        nested(acc, :session_options, :system, value)

      {"model", value}, acc ->
        acc |> Keyword.put(:model, value) |> nested(:session_options, :model, value)

      {"max_turns", value}, acc ->
        nested(acc, :session_options, :max_turns, value)

      {"reasoning_effort", value}, acc ->
        nested(acc, :session_options, :reasoning_effort, value)

      {"temperature", value}, acc ->
        session = Keyword.get(acc, :session_options, [])
        Keyword.put(acc, :session_options, nested(session, :params, :temperature, value))
    end)
  end

  defp nested(options, key, field, value),
    do: Keyword.put(options, key, Keyword.put(Keyword.get(options, key, []), field, value))

  defp cap_session(options, nil), do: options

  defp cap_session(options, reservation) do
    existing = get_in(options, [:session_options, :max_cost_usd])
    cap = if is_number(existing), do: min(existing, reservation), else: reservation
    nested(options, :session_options, :max_cost_usd, cap)
  end

  defp run_options(state, directory, opts) do
    state.benchmark_options
    |> Keyword.put(:workspace, :copy)
    |> Keyword.put(:output, Path.join(directory, "report.json"))
    |> Keyword.merge(Keyword.take(opts, [:progress]))
  end
end
