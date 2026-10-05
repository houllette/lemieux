defmodule Lemieux.Benchmark.CLI do
  @moduledoc false

  alias Lemieux.Benchmark
  alias Lemieux.Benchmark.Artifact
  alias Lemieux.Benchmark.Baseline
  alias Lemieux.Benchmark.Budget
  alias Lemieux.Benchmark.Change
  alias Lemieux.Benchmark.FixtureSet
  alias Lemieux.Benchmark.Gate
  alias Lemieux.Benchmark.Judging
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Runtime.Native
  alias Lemieux.Providers.ReqLLM
  alias Lemieux.Tool
  alias Lemieux.Tools

  @switches [
    suite: :string,
    fixture_set: :string,
    model: :keep,
    baseline: :string,
    tag: :keep,
    threshold: :float,
    max_regression: :float,
    concurrency: :integer,
    format: :string,
    output: :string,
    cost_cap: :float,
    estimated_cost: :float,
    seed: :integer,
    judge: :boolean,
    judge_model: :string,
    judge_cache: :string,
    approve_live: :boolean,
    change: :string,
    from: :string,
    to: :string
  ]

  @doc """
  Runs the standalone evaluation command without halting the VM.

  `host` carries what only the host knows: `:judge_provider`, a zero-arity
  function building the provider a judge request goes through, and
  `:default_judge_model`, a zero-arity function naming the judge model when
  `--judge-model` is absent. Both are functions so a run that never judges
  never reads the host's environment or configuration. Without them a judge
  uses a direct `Lemieux.Providers.ReqLLM` connection and
  `Lemieux.Benchmark.Judging.default_model/0`.
  """
  @spec run(args :: [String.t()], host :: keyword()) ::
          {:ok, map()} | {:gate_failed, map()} | {:error, term()}
  def run(args, host \\ []) when is_list(args) and is_list(host) do
    with {:ok, opts} <- parse(args),
         opts = judge_defaults(opts, host),
         :ok <- validate_approval(opts),
         :ok <- validate_cost(opts),
         {:ok, manifest} <- manifest(opts),
         {:ok, runtimes, default_baseline, mode} <- runtimes(opts, manifest),
         {:ok, baseline} <- baseline(opts, default_baseline),
         {:ok, change} <- change(opts),
         {:ok, report} <- run_benchmark(manifest, runtimes, opts),
         {:ok, report} <- Gate.evaluate(report, baseline: baseline, policy: policy(opts)),
         {:ok, report} <- maybe_judge(report, opts),
         {:ok, report} <- finalize(report, opts, mode, change) do
      verdict(report)
    end
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> validate_options(opts)
      {_opts, rest, invalid} -> {:error, {:invalid_arguments, rest, invalid}}
    end
  end

  defp validate_options(opts) do
    cond do
      not is_binary(opts[:suite]) ->
        {:error, :suite_required}

      opts[:format] not in [nil, "console", "json"] ->
        {:error, {:invalid_format, opts[:format]}}

      not positive?(Keyword.get(opts, :concurrency, 1)) ->
        {:error, :invalid_concurrency}

      opts[:fixture_set] && Keyword.get_values(opts, :model) != [] ->
        {:error, :ambiguous_runtime}

      is_nil(opts[:fixture_set]) and Keyword.get_values(opts, :model) == [] ->
        {:error, :runtime_required}

      true ->
        {:ok, opts}
    end
  end

  defp validate_approval(opts) do
    live? = Keyword.get_values(opts, :model) != [] or opts[:judge] == true
    if live? and opts[:approve_live] != true, do: {:error, :live_approval_required}, else: :ok
  end

  defp validate_cost(opts) do
    models = Keyword.get_values(opts, :model)
    paid? = models != [] or opts[:judge] == true
    validate_cost(paid?, opts[:cost_cap], opts[:estimated_cost])
  end

  defp validate_cost(true, cap, _estimate) when not is_number(cap) or cap <= 0,
    do: {:error, :live_cost_cap_required}

  defp validate_cost(true, _cap, estimate) when not is_number(estimate) or estimate < 0,
    do: {:error, :live_estimated_cost_required}

  defp validate_cost(_paid, cap, estimate)
       when is_number(estimate) and is_number(cap) and estimate > cap,
       do: {:error, {:estimated_cost_exceeds_cap, estimate, cap}}

  defp validate_cost(_paid, _cap, estimate) when is_number(estimate) and estimate < 0,
    do: {:error, :invalid_estimated_cost}

  defp validate_cost(_paid, _cap, _estimate), do: :ok

  defp manifest(opts) do
    with {:ok, manifest} <- Manifest.read(opts[:suite]),
         do: filter(manifest, Keyword.get_values(opts, :tag))
  end

  defp filter(manifest, []), do: {:ok, manifest}

  defp filter(%Manifest{} = manifest, tags) do
    tasks =
      Enum.filter(manifest.tasks, fn task ->
        task_tags = Map.get(task.metadata, "tags", [])
        Enum.any?(tags, &(&1 in task_tags))
      end)

    if tasks == [],
      do: {:error, {:no_tasks_for_tags, tags}},
      else: {:ok, %{manifest | tasks: tasks}}
  end

  defp runtimes(opts, manifest) do
    runtimes(opts, manifest, opts[:fixture_set])
  end

  defp runtimes(_opts, _manifest, fixture_set_path) when is_binary(fixture_set_path) do
    with {:ok, fixture_set} <- FixtureSet.read(fixture_set_path) do
      {:ok, fixture_set.runtimes, fixture_set.baseline, "fixture"}
    end
  end

  defp runtimes(opts, manifest, nil) do
    models = Keyword.get_values(opts, :model)
    total_cases = max(length(manifest.tasks) * length(models), 1)
    per_case_cap = opts[:cost_cap] / total_cases
    provider = ReqLLM.new()

    session_options = [max_cost_usd: per_case_cap] ++ equipped(manifest)

    runtimes =
      Enum.map(models, fn model ->
        Runtime.new(model, Native,
          provider: provider,
          model: model,
          session_options: session_options
        )
      end)

    default_baseline = if length(models) > 1, do: List.first(models), else: nil
    {:ok, runtimes, default_baseline, "live"}
  end

  # A manifest declares the catalog its cases are written against, and nothing read
  # it: every live run got the session's default of read, write, edit and bash, so
  # a case requiring `elixir` was unpassable and its `required_tools` recorded the
  # miss with nobody able to fix it.
  #
  # Asked of each tool rather than restated here, so renaming one cannot silently
  # stop it being equipped. `delegate` is deliberately absent: it is not a module
  # but a struct a host builds with `Lemieux.Subagent.Delegate.new/2`.
  @equippable [Tools.Read, Tools.Write, Tools.Edit, Tools.Bash, Tools.Eval, Tools.AskUser]

  defp equipped(%Manifest{metadata: %{"tools" => names}}) when is_list(names) do
    case Enum.filter(@equippable, &(Tool.name(&1) in names)) do
      [] -> []
      tools -> [tools: tools]
    end
  end

  defp equipped(_manifest), do: []

  defp baseline(opts, default) do
    case opts[:baseline] do
      nil ->
        {:ok, default}

      path_or_name ->
        if File.regular?(path_or_name), do: Baseline.read(path_or_name), else: {:ok, path_or_name}
    end
  end

  defp change(opts) do
    values = {opts[:change], opts[:from], opts[:to]}

    case values do
      {nil, nil, nil} ->
        {:ok, nil}

      {kind, from, to} when is_binary(kind) and is_binary(from) and is_binary(to) ->
        with :ok <- Change.validate(kind, from, to),
             do: {:ok, %{"kind" => kind, "from" => from, "to" => to}}

      _partial ->
        {:error, :incomplete_change}
    end
  end

  defp run_benchmark(manifest, runtimes, opts) do
    reservation =
      case {opts[:cost_cap], Keyword.get_values(opts, :model)} do
        {cap, models} when is_number(cap) and models != [] ->
          cap / max(length(manifest.tasks) * length(models), 1)

        _fixture_or_unbounded ->
          nil
      end

    Benchmark.run(manifest, runtimes,
      repetitions: 1,
      max_concurrency: Keyword.get(opts, :concurrency, 1),
      cost_cap_usd: opts[:cost_cap],
      estimated_cost_usd: opts[:estimated_cost],
      max_cost_per_attempt_usd: reservation
    )
  end

  defp policy(opts) do
    %{
      "minimum_task_success_rate" => Keyword.get(opts, :threshold, 0.8),
      "maximum_task_success_regression" => Keyword.get(opts, :max_regression, 0.03)
    }
  end

  # Resolved once, and only when a judge will run: the host's functions may
  # read its configuration, which a run that never judges has no business in.
  defp judge_defaults(opts, host) do
    if opts[:judge] do
      opts
      |> Keyword.put_new_lazy(:judge_model, fn -> host_default(host, :default_judge_model) end)
      |> Keyword.put_new_lazy(:judge_provider, fn -> host_value(host, :judge_provider) end)
    else
      Keyword.put_new(opts, :judge_model, Judging.default_model())
    end
  end

  defp host_default(host, key) do
    case host_value(host, key) do
      nil -> Judging.default_model()
      value -> value
    end
  end

  defp host_value(host, key) do
    case Keyword.get(host, key) do
      nil -> nil
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp maybe_judge(report, opts) do
    if opts[:judge] do
      Judging.run(
        report,
        [
          model: Keyword.fetch!(opts, :judge_model),
          threshold: Keyword.get(opts, :threshold, 0.8),
          cache: opts[:judge_cache]
        ] ++ if(opts[:judge_provider], do: [provider: opts[:judge_provider]], else: [])
      )
    else
      {:ok, report}
    end
  end

  defp run_metadata(opts, mode, change) do
    %{
      "mode" => mode,
      "change" => change,
      "tags" => Keyword.get_values(opts, :tag),
      "models" => Keyword.get_values(opts, :model),
      "seed" => Keyword.get(opts, :seed, 0),
      "concurrency" => Keyword.get(opts, :concurrency, 1),
      "output_format" => Keyword.get(opts, :format, "console"),
      "judge" => %{
        "enabled" => opts[:judge] == true,
        "model" => Keyword.fetch!(opts, :judge_model),
        "cache" => opts[:judge_cache]
      }
    }
  end

  defp finalize(report, opts, mode, change) do
    report =
      report
      |> Budget.apply(opts[:cost_cap], opts[:estimated_cost])
      |> Map.put("run", run_metadata(opts, mode, change))

    with :ok <- maybe_write(opts[:output], report), do: {:ok, report}
  end

  defp verdict(%{"gate" => %{"passed" => true}} = report), do: {:ok, report}
  defp verdict(report), do: {:gate_failed, report}

  defp maybe_write(nil, _report), do: :ok
  defp maybe_write(path, report), do: Artifact.write(path, report)

  defp positive?(value), do: is_integer(value) and value > 0
end
