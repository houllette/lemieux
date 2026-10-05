if Code.ensure_loaded?(Tribunal.Assertions) do
  defmodule Lemieux.Benchmark.Judging do
    @moduledoc """
    **Experimental.** May change in any 0.x release.
    Opt-in Tribunal LLM-as-judge scoring for genuinely subjective outputs.

    Only commit-message quality and explanation faithfulness are judged. Results
    are cached by the complete judge input, model and threshold; deterministic
    task success and safety never pass through an LLM.
    """

    alias Lemieux.Providers.ReqLLM
    alias Lemieux.Usage

    @default_model "openai:gpt-5-mini"
    @judge_modules [
      Lemieux.Benchmark.Judges.CommitQuality,
      Lemieux.Benchmark.Judges.ExplanationFaithfulness
    ]
    @judge_names %{
      "commit_quality" => :commit_quality,
      "explanation_faithfulness" => :explanation_faithfulness
    }
    @schema [
      verdict: [type: :string, required: true],
      reason: [type: :string, required: true],
      score: [type: :float]
    ]

    @doc """
    The judge model used when a host names none.

    A plain literal: which model a person's environment or personal
    configuration implies is the host's knowledge, and `mix lemieux.eval`
    resolves it before calling the benchmark command line.
    """
    @spec default_model() :: String.t()
    def default_model, do: @default_model

    @doc "Adds cached or newly judged output-quality metrics to an evaluated report."
    @spec run(report :: map(), keyword()) :: {:ok, map()} | {:error, term()}
    def run(report, opts \\ []) when is_map(report) and is_list(opts) do
      if Code.ensure_loaded?(Tribunal.Assertions) and
           Enum.all?(@judge_modules, &Code.ensure_loaded?/1) do
        do_run(report, opts)
      else
        {:error, :tribunal_not_available}
      end
    end

    defp do_run(report, opts) do
      model = Keyword.get(opts, :model, default_model())
      threshold = Keyword.get(opts, :threshold, 0.8)

      with {:ok, model, opts} <- prepare_inference(model, opts),
           {:ok, cache} <- read_cache(opts[:cache]),
           {:ok, results, cache, usages} <- judge_results(report, opts, model, threshold, cache),
           :ok <- write_cache(opts[:cache], cache) do
        report =
          report
          |> Map.put("results", results)
          |> put_quality_summary(threshold)
          |> Map.put("judge", %{
            "model" => model,
            "threshold" => threshold,
            "cache" => opts[:cache],
            "usage" => aggregate_usage(usages)
          })

        {:ok, report}
      end
    end

    defp prepare_inference(model, opts) do
      if Keyword.has_key?(opts, :llm) do
        {:ok, model, opts}
      else
        provider = Keyword.get_lazy(opts, :provider, &ReqLLM.new/0)

        with {:ok, provider, model} <- Lemieux.Ixway.prepare(provider, model) do
          {:ok, model, Keyword.put(opts, :llm, &request(provider, &1, &2, &3))}
        end
      end
    end

    defp judge_results(report, opts, model, threshold, cache) do
      tasks =
        report
        |> get_in(["manifest", "tasks"])
        |> List.wrap()
        |> Map.new(&{&1["id"], &1})

      Enum.reduce_while(report["results"], {:ok, [], cache, []}, fn result,
                                                                    {:ok, results, cache, usages} ->
        task = Map.get(tasks, result["task_id"], %{})

        case judge_result(result, task, opts, model, threshold, cache) do
          {:ok, result, cache, result_usages} ->
            {:cont, {:ok, [result | results], cache, result_usages ++ usages}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, results, cache, usages} -> {:ok, Enum.reverse(results), cache, usages}
        error -> error
      end
    end

    defp judge_result(result, task, opts, model, threshold, cache) do
      judges = get_in(task, ["metadata", "judges"]) || []

      with {:ok, judge_names} <- judge_names(judges),
           {:ok, verdicts, cache, usages} <-
             judge_all(judge_names, result, task, opts, model, threshold, cache) do
        finish_result(result, verdicts, cache, usages)
      end
    end

    defp judge_all(judges, result, task, opts, model, threshold, cache) do
      Enum.reduce_while(judges, {:ok, [], cache, []}, fn judge, {:ok, verdicts, cache, usages} ->
        case evaluate(judge, result, task, opts, model, threshold, cache) do
          {:ok, verdict, cache, usage} ->
            {:cont, {:ok, [verdict | verdicts], cache, List.wrap(usage) ++ usages}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end

    defp finish_result(result, verdicts, cache, usages) do
      verdicts = Enum.reverse(verdicts)
      applicable = length(verdicts)
      passed = applicable > 0 and Enum.all?(verdicts, &(&1["status"] == "pass"))

      metric = %{
        "applicable" => applicable > 0,
        "passed" => passed,
        "score" => if(passed, do: 1.0, else: 0.0),
        "judges" => verdicts
      }

      result =
        Map.update(
          result,
          "metrics",
          %{"output_quality" => metric},
          &Map.put(&1, "output_quality", metric)
        )

      {:ok, result, cache, usages}
    end

    defp evaluate(judge, result, task, opts, model, threshold, cache) do
      test_case = test_case(judge, result, task)
      key = cache_key(judge, test_case, model, threshold)

      case Map.fetch(cache, key) do
        {:ok, verdict} ->
          {:ok, verdict, cache, nil}

        :error ->
          llm = Keyword.fetch!(opts, :llm)
          register_judges()

          result =
            Tribunal.Assertions.evaluate(judge, test_case,
              model: model,
              threshold: threshold,
              llm: llm
            )

          usage = take_usage_message()

          with {:ok, verdict} <- verdict(judge, result) do
            {:ok, verdict, Map.put(cache, key, verdict), usage}
          end
      end
    end

    defp test_case(judge, result, task) do
      observation = result["observation"] || %{}
      answer = observation["answer"] || ""

      actual =
        if judge == :commit_quality,
          do: observation["commit_message"] || answer,
          else: answer

      evidence =
        observation["change_summary"] ||
          JSON.encode!(%{
            "changed_paths" => observation["changed_paths"],
            "grader" => result["grader"]
          })

      struct(Tribunal.TestCase,
        input: task["prompt"] || result["task_id"],
        actual_output: actual,
        context: [evidence],
        metadata: %{"task_id" => result["task_id"]}
      )
    end

    defp verdict(judge, {:pass, details}),
      do: {:ok, %{"judge" => to_string(judge), "status" => "pass", "details" => json(details)}}

    defp verdict(judge, {:fail, details}),
      do: {:ok, %{"judge" => to_string(judge), "status" => "fail", "details" => json(details)}}

    defp verdict(judge, {:error, reason}), do: {:error, {:judge_error, judge, reason}}

    defp judge_names(names) when is_list(names) do
      names
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, judges} ->
        case Map.fetch(@judge_names, name) do
          {:ok, judge} -> {:cont, {:ok, [judge | judges]}}
          :error -> {:halt, {:error, {:unknown_judge, name}}}
        end
      end)
      |> case do
        {:ok, judges} -> {:ok, Enum.reverse(judges)}
        error -> error
      end
    end

    defp judge_names(_names), do: {:error, :invalid_judges}

    defp register_judges do
      configured = Application.get_env(:tribunal, :custom_judges, [])
      Application.put_env(:tribunal, :custom_judges, Enum.uniq(@judge_modules ++ configured))
    end

    defp cache_key(judge, test_case, model, threshold) do
      payload = %{
        "schema_version" => 1,
        "judge" => to_string(judge),
        "model" => model,
        "threshold" => threshold,
        "input" => test_case.input,
        "output" => test_case.actual_output,
        "context" => test_case.context
      }

      :sha256 |> :crypto.hash(JSON.encode!(payload)) |> Base.encode16(case: :lower)
    end

    defp read_cache(nil), do: {:ok, %{}}

    defp read_cache(path) do
      case File.read(path) do
        {:ok, body} ->
          case JSON.decode(body) do
            {:ok, %{"schema_version" => 1, "entries" => entries}} when is_map(entries) ->
              {:ok, entries}

            {:ok, _invalid} ->
              {:error, :invalid_judge_cache}

            {:error, reason} ->
              {:error, {:invalid_judge_cache_json, Lemieux.JSON.describe_error(reason)}}
          end

        {:error, :enoent} ->
          {:ok, %{}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp write_cache(nil, _cache), do: :ok

    defp write_cache(path, cache) do
      with :ok <- File.mkdir_p(Path.dirname(Path.expand(path))) do
        File.write(path, [JSON.encode!(%{"schema_version" => 1, "entries" => cache}), ?\n])
      end
    end

    defp put_quality_summary(report, threshold) do
      summaries =
        report["results"]
        |> Enum.group_by(& &1["runtime"])
        |> Map.new(fn {runtime, results} ->
          metrics =
            results
            |> Enum.map(&get_in(&1, ["metrics", "output_quality"]))
            |> Enum.filter(&(&1 && &1["applicable"]))

          passed = Enum.count(metrics, & &1["passed"])
          rate = if metrics == [], do: nil, else: passed / length(metrics)
          {runtime, %{"applicable" => length(metrics), "passed" => passed, "rate" => rate}}
        end)

      report =
        Enum.reduce(summaries, report, fn {runtime, summary}, report ->
          put_in(report, ["evaluation", "runtimes", runtime, "output_quality"], summary)
        end)

      failures =
        Enum.flat_map(summaries, fn {runtime, summary} ->
          if summary["applicable"] > 0 and summary["rate"] < threshold do
            [
              %{
                "runtime" => runtime,
                "metric" => "output_quality",
                "hard" => false,
                "rate" => summary["rate"],
                "minimum" => threshold
              }
            ]
          else
            []
          end
        end)

      if failures == [] do
        report
      else
        report
        |> put_in(["gate", "passed"], false)
        |> update_in(["gate", "failures"], &(failures ++ &1))
      end
    end

    defp request(provider, model, messages, opts) do
      request = judge_request(model, messages, opts)
      reference = make_ref()
      result = Lemieux.Provider.run(provider, request, &send(self(), {reference, &1}))
      {message, usage} = collect_response(reference, nil, nil)
      judge_response(result, message, usage, model)
    end

    defp judge_response(:ok, message, usage, model) do
      if usage, do: send(self(), {:lemieux_judge_usage, usage, model})
      decode_verdict(message)
    end

    defp judge_response({:error, _} = error, _message, _usage, _model), do: error

    defp judge_request(model, messages, opts) do
      {system, conversation} = Enum.split_with(messages, &(&1.role == "system"))

      entries =
        conversation
        |> Enum.with_index(1)
        |> Enum.map(&judge_entry/1)

      Lemieux.Request.new(model,
        system: Enum.map_join(system, "\n", & &1.content),
        entries: entries,
        output_schema: @schema,
        params: Keyword.take(opts, [:temperature, :max_tokens])
      )
    end

    defp judge_entry({%{role: "assistant", content: text}, seq}) do
      Lemieux.Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => text}]},
        seq: seq
      )
    end

    defp judge_entry({%{role: "user", content: text}, seq}),
      do: Lemieux.Entry.new(:user, %{"text" => text}, seq: seq)

    defp collect_response(reference, message, usage) do
      receive do
        {^reference, {:message, value}} -> collect_response(reference, value, usage)
        {^reference, {:usage, value}} -> collect_response(reference, message, value)
        {^reference, _event} -> collect_response(reference, message, usage)
      after
        0 -> {message, usage}
      end
    end

    defp decode_verdict(%{"content" => content}) do
      text = Enum.map_join(content, "", &Map.get(&1, "text", ""))

      case JSON.decode(text) do
        {:ok, object} when is_map(object) -> {:ok, object}
        _ -> {:error, :invalid_judge_response}
      end
    end

    defp decode_verdict(_message), do: {:error, :invalid_judge_response}

    defp take_usage_message do
      receive do
        {:lemieux_judge_usage, usage, model} when is_map(usage) -> Usage.normalize(usage, model)
      after
        0 -> nil
      end
    end

    defp aggregate_usage([]), do: Usage.empty()
    defp aggregate_usage(usages), do: Usage.sum(usages)

    defp json(map) when is_map(map),
      do: Map.new(map, fn {key, value} -> {to_string(key), json(value)} end)

    defp json(list) when is_list(list), do: Enum.map(list, &json/1)
    defp json(value) when is_atom(value), do: to_string(value)
    defp json(value), do: value
  end
else
  defmodule Lemieux.Benchmark.Judging do
    @moduledoc false

    @doc false
    @spec default_model() :: String.t()
    def default_model, do: "openai:gpt-5-mini"

    @doc false
    @spec run(report :: map(), keyword()) :: {:error, :tribunal_not_available}
    def run(_report, _opts \\ []), do: {:error, :tribunal_not_available}
  end
end
