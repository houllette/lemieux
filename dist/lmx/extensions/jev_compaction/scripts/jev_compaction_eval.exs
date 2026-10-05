defmodule JevCompactionEval do
  @moduledoc false

  alias Lemieux.Providers.ReqLLM
  alias LemieuxJevCompaction.Evaluation
  alias LemieuxJevCompaction.Trial

  @switches [
    model: :string,
    corpus: :string,
    output: :string,
    tariff: :string,
    arms: :string,
    repetitions: :integer,
    threshold: :float,
    production_defaults: :boolean,
    cost_cap: :float,
    reservation_per_run: :float
  ]

  def run(args) do
    with {options, [], []} <- OptionParser.parse(args, strict: @switches),
         {:ok, settings} <- settings(options),
         {:ok, env} <- private_env(),
         {:ok, key} <- provider_key(env, settings.model),
         {:ok, jev_key} <- jev_key(env, settings.arms),
         {:ok, cases} <- Trial.read_corpus(settings.corpus),
         {:ok, tiers} <- tariff(settings.tariff, settings.model),
         {:ok, report} <- trial(cases, settings, key, jev_key, tiers),
         {:ok, analyzed} <- analyze(report, settings, tiers),
         :ok <- write_report(analyzed, settings.output) do
      IO.puts("Completed #{length(report["runs"])} runs; report: #{settings.output}")
      :ok
    else
      {:error, reason, partial} ->
        IO.puts(
          :stderr,
          "Trial stopped: #{inspect(reason)}; #{length(partial["runs"])} complete runs"
        )

        {:error, reason}

      {:error, reason} ->
        IO.puts(:stderr, "Trial stopped: #{inspect(reason)}")
        {:error, reason}

      _invalid ->
        IO.puts(:stderr, "Invalid arguments; see dist/lmx/extensions/jev_compaction/README.md")
        {:error, :invalid_arguments}
    end
  end

  defp settings(options) do
    arms =
      options
      |> Keyword.get(:arms, "baseline,shadow,jev,summary")
      |> String.split(",", trim: true)
      |> Enum.map(fn
        "baseline" -> :baseline
        "shadow" -> :shadow
        "jev" -> :jev
        "summary" -> :summary
        _unknown -> :invalid
      end)

    settings = %{
      model: Keyword.get(options, :model, "openai:gpt-5-mini"),
      corpus: Keyword.get(options, :corpus, "eval/v1/cases.json"),
      output: Keyword.get(options, :output, "tmp/jev_compaction_eval.json"),
      tariff: Keyword.get(options, :tariff),
      arms: arms,
      repetitions: Keyword.get(options, :repetitions, 1),
      threshold: Keyword.get(options, :threshold, 0.1),
      production_defaults: Keyword.get(options, :production_defaults, false),
      cost_cap: options[:cost_cap],
      reservation_per_run: options[:reservation_per_run]
    }

    cond do
      not (is_number(settings.cost_cap) and is_number(settings.reservation_per_run)) ->
        {:error, :cost_reservation_required}

      settings.threshold < 0 or settings.threshold > 1 ->
        {:error, :invalid_threshold}

      not output_in_tmp?(settings.output) ->
        {:error, :output_must_be_in_tmp}

      true ->
        {:ok, settings}
    end
  rescue
    ArgumentError -> {:error, :invalid_arms}
  end

  defp output_in_tmp?(path) do
    root = Path.expand("tmp", File.cwd!())
    target = Path.expand(path)
    String.starts_with?(target, root <> "/") and Path.extname(target) == ".json"
  end

  defp private_env do
    # The checkout root, five levels up from dist/lmx/extensions/jev_compaction/scripts.
    root = Path.expand("../../../../../.env", __DIR__)
    Dotenvy.source([root, System.get_env()], side_effect: fn _ -> :ok end)
  end

  defp provider_key(env, model) do
    name = model |> String.split(":", parts: 2) |> List.first()

    variable =
      case name do
        "openai" -> "OPENAI_API_KEY"
        "zai" -> "ZAI_API_KEY"
        "zai_coding_plan" -> "ZAI_API_KEY"
        _ -> nil
      end

    if (variable && is_binary(env[variable])) and env[variable] != "",
      do: {:ok, {name, env[variable]}},
      else: {:error, :provider_key_unavailable}
  end

  defp jev_key(env, arms) do
    if Enum.any?(arms, &(&1 in [:shadow, :jev])) do
      if is_binary(env["JEV_API_KEY"]) and env["JEV_API_KEY"] != "",
        do: {:ok, env["JEV_API_KEY"]},
        else: {:error, :jev_key_unavailable}
    else
      {:ok, nil}
    end
  end

  defp tariff(nil, _model), do: {:ok, nil}

  defp tariff(path, model) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"model" => ^model, "tiers" => tiers}} when is_list(tiers) <- JSON.decode(bytes),
         true <- Enum.any?(tiers, &(&1["up_to"] == nil)),
         {:ok, _priced} <-
           Evaluation.price(%{"input_tokens" => 1_000_000_000, "output_tokens" => 0}, tiers) do
      {:ok, tiers}
    else
      _ -> {:error, :invalid_tariff}
    end
  end

  defp trial(cases, settings, {provider, key}, jev_key, tiers) do
    Trial.run(cases,
      model: settings.model,
      arms: settings.arms,
      repetitions: settings.repetitions,
      cost_cap_usd: settings.cost_cap,
      reservation_per_run_usd: settings.reservation_per_run,
      provider_factory: fn _, _, _ -> ReqLLM.new(api_keys: %{provider => key}) end,
      provider_tiers: tiers,
      jev_api_key: jev_key,
      sdk_rates: %{"input_per_million" => 0.042, "output_per_million" => 0.0},
      keep_threshold: settings.threshold,
      hook_opts: [min_saved_tokens: 1],
      production_defaults: settings.production_defaults
    )
  end

  defp analyze(report, settings, tiers) do
    evaluations =
      report["runs"]
      |> Enum.filter(&(&1["arm"] == "shadow"))
      |> Enum.flat_map(& &1["evaluations"])

    with {:ok, sweep} <-
           Evaluation.sweep(evaluations, [0.02, 0.05, 0.1, 0.2, 0.5, 1.0], min_saved_tokens: 1),
         {:ok, pairs} <- comparisons(report["runs"], tiers) do
      {:ok,
       report
       |> Map.put("score_sweep", sweep)
       |> Map.put("pair_comparisons", pairs)
       |> Map.put("selected_threshold", settings.threshold)
       |> Map.put("run_summary", summary(report["runs"]))
       |> Map.put(
         "pricing_basis",
         if(settings.tariff, do: "supplied_tariff", else: "provider_reported")
       )}
    end
  end

  defp comparisons(_runs, nil), do: {:ok, []}

  defp comparisons(runs, tiers) do
    runs
    |> Enum.group_by(&{&1["case_id"], &1["repetition"]})
    |> Enum.reduce_while({:ok, []}, fn {{case_id, repetition}, group}, {:ok, pairs} ->
      by_arm = Map.new(group, &{&1["arm"], &1})
      baseline = by_arm["baseline"]

      if baseline do
        result =
          Enum.reduce_while(["shadow", "jev", "summary"], {:ok, pairs}, fn arm, {:ok, pairs} ->
            case by_arm[arm] do
              nil ->
                {:cont, {:ok, pairs}}

              projected ->
                sdk = Enum.map(projected["evaluations"], & &1["sdk_usage"])

                case Evaluation.compare(
                       usages(baseline),
                       usages(projected),
                       sdk,
                       tiers,
                       %{"input_per_million" => 0.042, "output_per_million" => 0.0}
                     ) do
                  {:ok, result} ->
                    row =
                      result
                      |> Map.put("case_id", case_id)
                      |> Map.put("repetition", repetition)
                      |> Map.put("arm", arm)

                    {:cont, {:ok, [row | pairs]}}

                  {:error, _reason} = error ->
                    {:halt, error}
                end
            end
          end)

        case result do
          {:ok, next_pairs} -> {:cont, {:ok, next_pairs}}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, pairs}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  defp usages(run), do: Enum.flat_map(run["followups"], & &1["usage"])

  defp summary(runs) do
    runs
    |> Enum.group_by(& &1["arm"])
    |> Map.new(fn {arm, rows} ->
      turns = Enum.flat_map(rows, & &1["followups"])

      {arm,
       %{
         "runs" => length(rows),
         "correct_turns" => Enum.count(turns, & &1["correct"]),
         "total_turns" => length(turns),
         "cost_usd" => Enum.sum(Enum.map(rows, & &1["total_cost_usd"])),
         "elapsed_ms" => turns |> Enum.map(& &1["elapsed_ms"]) |> Enum.sum()
       }}
    end)
  end

  defp write_report(report, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, JSON.encode!(report) <> "\n") do
      :ok
    end
  end
end

case JevCompactionEval.run(System.argv()) do
  :ok -> :ok
  {:error, reason} -> Mix.raise("Jev compaction evaluation failed: #{inspect(reason)}")
end
