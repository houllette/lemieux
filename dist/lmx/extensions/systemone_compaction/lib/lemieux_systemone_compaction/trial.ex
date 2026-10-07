defmodule LemieuxSystemOneCompaction.Trial do
  @moduledoc """
  Runs paired, mechanically graded continuations from the same seeded reads.

  Each arm gets a fresh work directory and an independently replayed seed
  transcript. The seed uses Lemieux's real `read` tool but a scripted provider;
  only follow-up turns use the supplied provider. The scoring arms (`shadow`
  and `projection`) assemble this extension through the normal harness, with
  TypeSafe's hosted provider unless the caller supplies an SDK client. The
  report contains case IDs, exact-answer verdicts, bounded scorer
  observations, provider usage, and whether
  the original read outputs remain intact in the transcript. It never serializes
  prompts, file contents, responses, clients or credentials.

  The caller must reserve a worst-case amount for every arm before execution.
  Actual measured or tariff-priced cost is checked after each arm, and unknown
  usage stops the run. This is a local evaluation harness, not a production
  billing or sandbox boundary. Hosts own the fixture corpus and provider keys.
  """

  alias Lemieux.Entry
  alias Lemieux.Benchmark.Resources
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias LemieuxSystemOneCompaction, as: SystemOneCompaction
  alias LemieuxSystemOneCompaction.Evaluation

  @arms [:baseline, :shadow, :projection, :summary]
  @max_runs 200
  @usage_keys ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens input_includes_cached cost_usd)

  @type case_data :: map()

  @doc "Runs a bounded paired trial and returns a content-free JSON-shaped report."
  @spec run(cases :: [case_data()], opts :: keyword()) ::
          {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def run(cases, opts) when is_list(cases) and is_list(opts) do
    with :ok <- admit(cases, opts),
         :ok <- validate_cases(cases),
         {:ok, runs, spent} <- execute(cases, opts) do
      {:ok,
       %{
         "schema_version" => 1,
         "model" => Keyword.fetch!(opts, :model),
         "cost_cap_usd" => Keyword.fetch!(opts, :cost_cap_usd),
         "reservation_per_run_usd" => Keyword.fetch!(opts, :reservation_per_run_usd),
         "cost_usd" => spent,
         "runs" => runs
       }}
    end
  end

  def run(_cases, _opts), do: {:error, :invalid_trial}

  @doc "Reads a JSON corpus and rejects unsafe or incomplete fixture paths."
  @spec read_corpus(path :: Path.t()) :: {:ok, [case_data()]} | {:error, term()}
  def read_corpus(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"version" => 1, "cases" => cases}} <- JSON.decode(contents),
         :ok <- validate_cases(cases) do
      {:ok, cases}
    else
      {:ok, _invalid} -> {:error, :invalid_corpus}
      {:error, _reason} = error -> error
    end
  end

  defp admit(cases, opts) do
    arms = Keyword.get(opts, :arms, @arms)
    repetitions = Keyword.get(opts, :repetitions, 1)
    cap = Keyword.get(opts, :cost_cap_usd)
    reservation = Keyword.get(opts, :reservation_per_run_usd)
    count = length(cases) * length(List.wrap(arms)) * repetitions

    cond do
      not (is_list(arms) and arms != [] and Enum.all?(arms, &(&1 in @arms)) and
               length(Enum.uniq(arms)) == length(arms)) ->
        {:error, :invalid_arms}

      not (is_integer(repetitions) and repetitions > 0 and count <= @max_runs) ->
        {:error, :invalid_repetitions}

      not valid_limit?(Keyword.get(opts, :max_turns, 4), 8) or
          not valid_limit?(Keyword.get(opts, :max_requests, 8), 16) ->
        {:error, :invalid_request_limit}

      not (is_number(cap) and cap > 0 and is_number(reservation) and reservation > 0) ->
        {:error, :cost_reservation_required}

      count * reservation > cap ->
        {:error, :cost_cap_exceeded}

      not is_binary(opts[:model]) or not is_function(opts[:provider_factory], 3) ->
        {:error, :provider_required}

      Enum.any?(arms, &(&1 in [:shadow, :projection])) and not sdk_available?(opts) ->
        {:error, :sdk_required}

      not valid_sdk_rates?(opts[:sdk_rates]) ->
        {:error, :sdk_rates_required}

      true ->
        :ok
    end
  end

  defp sdk_available?(opts),
    do: match?(%SystemOneSDK.Client{}, opts[:sdk_client]) or is_binary(opts[:typesafe_api_key])

  defp valid_limit?(value, ceiling), do: is_integer(value) and value > 0 and value <= ceiling

  defp valid_sdk_rates?(%{"input_per_million" => input, "output_per_million" => output}),
    do: is_number(input) and input >= 0 and is_number(output) and output >= 0

  defp valid_sdk_rates?(_rates), do: false

  defp validate_cases(cases) when is_list(cases) and cases != [] do
    if Enum.all?(cases, &valid_case?/1) and
         cases |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(cases),
       do: :ok,
       else: {:error, :invalid_case}
  end

  defp validate_cases(_cases), do: {:error, :invalid_case}

  defp valid_case?(
         %{"id" => id, "files" => files, "seed_reads" => reads, "followups" => turns} =
           case_data
       )
       when is_binary(id) and byte_size(id) in 1..80 and is_list(files) and files != [] and
              length(files) <= 20 and is_list(reads) and reads != [] and is_list(turns) and
              turns != [] and length(turns) <= 4 do
    file_paths = Enum.map(files, & &1["path"])
    labels = Map.get(case_data, "must_keep_by_path", %{})
    mutations = Map.get(case_data, "mutations", %{})

    String.match?(id, ~r/\A[a-zA-Z0-9_-]+\z/) and
      valid_category?(Map.get(case_data, "category")) and
      Enum.all?(files, &valid_file?/1) and Enum.uniq(file_paths) == file_paths and
      Enum.all?(reads, &(&1 in file_paths)) and
      Enum.all?(turns, &valid_followup?/1) and is_map(labels) and
      Enum.all?(labels, fn {path, value} -> path in file_paths and is_boolean(value) end) and
      is_map(mutations) and
      Enum.all?(mutations, fn {path, text} ->
        path in file_paths and is_binary(text) and byte_size(text) <= 1_000
      end)
  end

  defp valid_case?(_case_data), do: false

  defp valid_category?(nil), do: true

  defp valid_category?(category) when is_binary(category) and byte_size(category) in 1..80,
    do: String.match?(category, ~r/\A[a-zA-Z0-9_-]+\z/)

  defp valid_category?(_category), do: false

  defp valid_file?(%{
         "path" => path,
         "line_count" => count,
         "target_line" => target,
         "target_text" => text
       }) do
    safe_path?(path) and is_integer(count) and count in 1..2_000 and
      is_integer(target) and target in 1..count and is_binary(text) and byte_size(text) <= 1_000
  end

  defp valid_file?(_file), do: false

  defp safe_path?(path) when is_binary(path) and byte_size(path) in 1..200 do
    Path.type(path) == :relative and path != "." and
      not Enum.member?(Path.split(path), "..")
  end

  defp safe_path?(_path), do: false

  defp valid_followup?(%{"prompt" => prompt, "expected" => expected}),
    do:
      is_binary(prompt) and byte_size(prompt) in 1..4_000 and is_binary(expected) and
        byte_size(expected) <= 500

  defp valid_followup?(_turn), do: false

  defp execute(cases, opts) do
    arms = Keyword.get(opts, :arms, @arms)
    repetitions = Keyword.get(opts, :repetitions, 1)
    cap = Keyword.fetch!(opts, :cost_cap_usd)

    plan =
      for repetition <- 1..repetitions,
          {case_data, index} <- Enum.with_index(cases),
          arm <- rotate(arms, repetition + index - 1),
          do: {case_data, arm, repetition}

    Enum.reduce_while(plan, {:ok, [], 0.0}, fn {case_data, arm, repetition}, {:ok, runs, spent} ->
      case run_one(case_data, arm, repetition, opts) do
        {:ok, row, cost} when spent + cost <= cap ->
          {:cont, {:ok, [row | runs], spent + cost}}

        {:ok, row, _cost} ->
          {:halt, {:error, :cost_cap_exceeded, partial_report([row | runs], opts)}}

        {:error, reason} ->
          {:halt, {:error, reason, partial_report(runs, opts)}}
      end
    end)
    |> case do
      {:ok, runs, spent} -> {:ok, Enum.reverse(runs), spent}
      other -> other
    end
  end

  defp rotate(arms, offset) do
    {left, right} = Enum.split(arms, rem(offset, length(arms)))
    right ++ left
  end

  defp partial_report(runs, opts) do
    %{"model" => opts[:model], "runs" => Enum.reverse(runs), "complete" => false}
  end

  defp run_one(case_data, arm, repetition, opts) do
    unique = System.unique_integer([:positive])
    directory = Path.join(System.tmp_dir!(), "lemieux_systemone_trial_#{unique}")
    runtime_name = :"systemone_trial_#{unique}"
    File.mkdir_p!(directory)

    try do
      with :ok <- write_files(case_data, directory),
           {:ok, runtime} <- Lemieux.Supervisor.start_link(name: runtime_name) do
        try do
          run_session(case_data, arm, repetition, opts, runtime_name, directory)
        after
          Supervisor.stop(runtime)
        end
      end
    after
      File.rm_rf(directory)
    end
  end

  defp write_files(%{"files" => files}, directory) do
    Enum.each(files, fn file ->
      path = Path.join(directory, file["path"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, render_file(file))
    end)
  end

  defp render_file(file) do
    for number <- 1..file["line_count"] do
      if number == file["target_line"],
        do: file["target_text"] <> "\n",
        else: "def archived_step_#{number}, do: :ok\n"
    end
  end

  defp run_session(case_data, arm, repetition, opts, runtime, directory) do
    store = JSONL.new(directory)
    scripted = Scripted.new(seed_script(case_data["seed_reads"]))

    with {:ok, seeded} <-
           Lemieux.start_session(
             supervisor: runtime,
             provider: scripted,
             store: store,
             model: opts[:model],
             cwd: directory,
             context_window: Keyword.get(opts, :context_window, 1_000_000),
             compact_at: nil,
             tools: [Lemieux.Tools.Read],
             params: output_params(opts),
             subscriber: self()
           ),
         :ok <- Session.prompt(seeded, "Read the listed files for this earlier task."),
         :stop <- await(Session.id(seeded)),
         {:ok, seed} <- seed_evidence(seeded, case_data),
         {:ok, session_id} <- {:ok, Session.id(seeded)},
         :ok <-
           DynamicSupervisor.terminate_child(
             Lemieux.Supervisor.session_supervisor(runtime),
             seeded
           ),
         :ok <- mutate_files(case_data, directory),
         {:ok, resumed} <-
           resume(case_data, arm, repetition, opts, runtime, store, directory, session_id) do
      followups(resumed, case_data, arm, repetition, opts, seed)
    else
      _failure -> {:error, :seed_or_resume_failed}
    end
  end

  defp seed_script(paths) do
    calls =
      paths
      |> Enum.with_index(1)
      |> Enum.map(fn {path, index} ->
        {:tool_call, %{id: "read-#{index}", name: "read", arguments: %{"path" => path}}}
      end)

    [calls ++ [{:done, :tool_calls}], Scripted.complete("Read complete.")]
  end

  defp output_params(opts) do
    limit = Keyword.get(opts, :max_output_tokens, 256)

    if String.starts_with?(opts[:model], "openai:"),
      do: [max_completion_tokens: limit],
      else: [max_tokens: limit]
  end

  defp await(id) do
    receive do
      {:lemieux, ^id, {:finished, reason}} -> reason
    after
      90_000 -> :timeout
    end
  end

  defp seed_evidence(session, case_data) do
    results = Enum.filter(Session.snapshot(session).entries, &(&1.type == :tool_result))

    if length(results) == length(case_data["seed_reads"]) and
         Enum.all?(results, &(&1.payload["error"] == false and is_binary(&1.payload["output"]))) do
      {:ok,
       %{
         paths: Map.new(results, &{&1.id, &1.payload["arguments"]["path"]}),
         output_hashes: Map.new(results, &{&1.id, output_hash(&1.payload["output"])})
       }}
    else
      {:error, :seed_read_failed}
    end
  end

  defp mutate_files(case_data, directory) do
    files = Map.new(case_data["files"], &{&1["path"], &1})

    Enum.each(Map.get(case_data, "mutations", %{}), fn {path, replacement} ->
      file = Map.fetch!(files, path)
      changed = Map.put(file, "target_text", replacement)
      File.write!(Path.join(directory, path), render_file(changed))
    end)
  end

  defp resume(case_data, arm, repetition, opts, runtime, store, directory, session_id) do
    provider = opts[:provider_factory].(case_data, arm, repetition)

    with {:ok, harness} <- arm_harness(arm, opts) do
      Lemieux.resume_session(
        supervisor: runtime,
        provider: provider,
        store: store,
        resume: session_id,
        cwd: directory,
        max_turns: Keyword.get(opts, :max_turns, 4),
        max_requests: Keyword.get(opts, :max_requests, 8),
        params: output_params(opts),
        context_window:
          if(arm == :summary,
            do: Keyword.get(opts, :summary_context_window, 40_000),
            else: Keyword.get(opts, :context_window, 1_000_000)
          ),
        compact_at: if(arm == :summary, do: Keyword.get(opts, :summary_compact_at, 0.1)),
        keep_recent_tokens: Keyword.get(opts, :summary_keep_recent_tokens, 256),
        harness: harness,
        subscriber: self()
      )
    end
  end

  defp arm_harness(:baseline, _opts), do: {:ok, Harness.new()}
  defp arm_harness(:summary, _opts), do: {:ok, Harness.new()}

  defp arm_harness(arm, opts) do
    defaults =
      if Keyword.get(opts, :production_defaults, false) do
        [keep_threshold: Keyword.get(opts, :keep_threshold, 0.1)]
      else
        [
          activation_tokens: 1,
          preserve_recent_entries: 0,
          min_result_chars: 1,
          min_saved_tokens: 1,
          max_evaluations: 4,
          keep_threshold: Keyword.get(opts, :keep_threshold, 0.1)
        ]
      end

    options =
      defaults
      |> Keyword.merge(Keyword.get(opts, :hook_opts, []))
      |> Keyword.put(:mode, if(arm == :shadow, do: :shadow, else: :apply))

    options =
      case opts[:sdk_client] do
        %SystemOneSDK.Client{} = client -> Keyword.put(options, :client, client)
        _no_client -> Keyword.put(options, :provider, typesafe(opts[:typesafe_api_key]))
      end

    Harness.assemble(Harness.new(), [{SystemOneCompaction, options}])
  end

  # The hosted scorer, as `Lemieux.CLI.SystemOneCompaction` describes it: the
  # trial measures TypeSafe's service unless the caller hands it a client.
  defp typesafe(key),
    do: %{
      name: "typesafe",
      type: :typesafe,
      base_url: "https://api.typesafe.ai",
      api_key: key,
      api_key_header: nil,
      headers: %{},
      model: nil
    }

  defp followups(session, case_data, arm, repetition, opts, seed) do
    id = Session.id(session)

    result =
      Enum.reduce_while(case_data["followups"], {:ok, []}, fn turn, {:ok, rows} ->
        before_count = session |> Session.snapshot() |> Map.fetch!(:entries) |> length()
        started = System.monotonic_time(:millisecond)

        with :ok <- Session.prompt(session, turn["prompt"]) do
          reason = await(id)
          elapsed = max(System.monotonic_time(:millisecond) - started, 0)

          entries =
            session |> Session.snapshot() |> Map.fetch!(:entries) |> Enum.drop(before_count)

          row = grade_turn(turn, reason, elapsed, entries)
          {:cont, {:ok, [row | rows]}}
        else
          _failure -> {:halt, {:error, :prompt_failed}}
        end
      end)

    case result do
      {:ok, rows} ->
        {evaluations, sdk_attempts} = observations(session, case_data, seed.paths)
        rows = Enum.reverse(rows)
        usages = Enum.flat_map(rows, & &1["usage"])
        sdk_usages = Enum.map(evaluations, & &1["sdk_usage"])

        with true <- Enum.all?(rows, & &1["usage_complete"]),
             true <- sdk_attempts == length(evaluations),
             {:ok, provider_cost} <- provider_cost(usages, opts),
             {:ok, sdk_cost} <- sdk_cost(sdk_usages, opts) do
          row = %{
            "case_id" => case_data["id"],
            "category" => Map.get(case_data, "category"),
            "arm" => Atom.to_string(arm),
            "repetition" => repetition,
            "followups" => rows,
            "evaluations" => evaluations,
            "extension_attached" => extension_attached?(session),
            "transcript_preserved" => transcript_preserved?(session, seed.output_hashes),
            "provider_cost_usd" => provider_cost,
            "provider_reported_cost_usd" => reported_provider_cost(usages),
            "sdk_cost_usd" => sdk_cost,
            "total_cost_usd" => provider_cost + sdk_cost
          }

          {:ok, row, provider_cost + sdk_cost}
        else
          false -> {:error, :incomplete_paid_usage}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp extension_attached?(session) do
    session
    |> Session.snapshot()
    |> Map.fetch!(:harness_context)
    |> get_in(["extensions", "applied"])
    |> List.wrap()
    |> Enum.any?(&(&1["module"] == "LemieuxSystemOneCompaction"))
  end

  defp transcript_preserved?(session, original_hashes) do
    stored_hashes =
      session
      |> Session.snapshot()
      |> Map.fetch!(:entries)
      |> Enum.filter(&(&1.type == :tool_result and is_binary(&1.payload["output"])))
      |> Map.new(&{&1.id, output_hash(&1.payload["output"])})

    Enum.all?(original_hashes, fn {id, hash} -> Map.get(stored_hashes, id) == hash end)
  end

  defp output_hash(output), do: :crypto.hash(:sha256, output)

  defp grade_turn(turn, reason, elapsed_ms, entries) do
    assistant = entries |> Enum.filter(&(&1.type == :assistant)) |> List.last()
    answer = if assistant, do: assistant_text(assistant), else: ""

    usages =
      for %Entry{type: type, usage: usage} <- entries,
          type in [:assistant, :compaction, :error],
          is_map(usage),
          do: Map.take(usage, @usage_keys)

    %{
      "correct" => reason == :stop and String.trim(answer) == turn["expected"],
      "status" => if(reason == :stop, do: "stop", else: "failed"),
      "elapsed_ms" => elapsed_ms,
      "usage_complete" =>
        (resources = Resources.from_entries(entries))["tokens_complete"] and
          resources["requests"] > 0,
      "usage" => usages
    }
  end

  defp assistant_text(%Entry{payload: payload}) do
    payload
    |> Map.get("content", [])
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp observations(session, case_data, path_by_entry) do
    labels = Map.get(case_data, "must_keep_by_path", %{})

    case Session.document(session, "systemone_compaction") do
      {:ok, %{value: %{"evaluations" => evaluations, "attempts" => attempts}}} ->
        rows =
          Enum.map(evaluations, fn evaluation ->
            candidates =
              Enum.map(evaluation["candidates"], fn candidate ->
                path = Map.get(path_by_entry, candidate["entry_id"])
                Map.put(candidate, "must_keep", Map.get(labels, path))
              end)

            evaluation
            |> Map.put("candidates", candidates)
            |> Map.take(~w(mode candidates estimated_saved_tokens applied latency_ms sdk_usage))
          end)

        {rows, attempts}

      _none ->
        {[], 0}
    end
  end

  defp provider_cost([], _opts), do: {:error, :incomplete_provider_usage}

  defp provider_cost(usages, opts) do
    Enum.reduce_while(usages, {:ok, 0.0}, fn usage, {:ok, total} ->
      case opts[:provider_tiers] do
        tiers when is_list(tiers) ->
          case Evaluation.price(usage, tiers) do
            {:ok, %{"cost_usd" => cost}} -> {:cont, {:ok, total + cost}}
            {:error, _reason} -> {:halt, {:error, :incomplete_provider_usage}}
          end

        _missing ->
          case usage["cost_usd"] do
            cost when is_number(cost) and cost >= 0 -> {:cont, {:ok, total + cost}}
            _unknown -> {:halt, {:error, :incomplete_provider_usage}}
          end
      end
    end)
  end

  defp reported_provider_cost(usages) do
    costs = Enum.map(usages, & &1["cost_usd"])
    if Enum.all?(costs, &(is_number(&1) and &1 >= 0)), do: Enum.sum(costs)
  end

  defp sdk_cost(usages, opts) do
    tier = Map.put(opts[:sdk_rates], "up_to", nil)

    Enum.reduce_while(usages, {:ok, 0.0}, fn usage, {:ok, total} ->
      case Evaluation.price(usage, [tier]) do
        {:ok, %{"cost_usd" => cost}} -> {:cont, {:ok, total + cost}}
        {:error, _reason} -> {:halt, {:error, :incomplete_sdk_usage}}
      end
    end)
  end
end
