defmodule Lemieux.Learning.Experience.Retrieval do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Deterministic, bounded retrieval of scoped lessons for a later proposal.

  `freeze/3` pins an inventory, not authority. Every inspection or retrieval
  re-reads and verifies current bytes, scope, freshness and retention. A
  frozen control ignores later appends; an updating arm freezes a new
  inventory at each task boundary. Pruned records stay unavailable in either.

  Applicability cues must overlap the query before ranking. Scores count
  unique matching words, with fixed weights and id tie-breaking. Relevant
  rejected/contradicted lessons are counterexamples, never instructions; one
  result slot is reserved for the best counterexample when one exists.

  Inspection returns only a digested decision receipt. `retrieve/7` commits
  the complete source-case exposure before returning concise notes and bounded
  evidence files for on-demand reading. It makes no provider call, changes no
  harness, and does no model-backed reflection. The ordinary proposer sessions
  retain their existing host-authorized accounting and limits.

  Source reads, result count, receipt size and evidence bytes have finite
  limits. An incomplete scan refuses release instead of claiming a partial
  ranking describes the frozen library. Adapters opt into `Lessons.inventory/1`
  and `Lessons.fetch/3`; unsupported adapters fail explicitly.
  """

  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Contract
  alias Lemieux.Learning.Experience.Lesson
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Experience.Retrieval.Evidence

  @limits [
    max_entries: 1000,
    max_source_bytes: 8 * 1024 * 1024,
    max_results: 4,
    max_decisions: 128,
    max_note_bytes: 1024,
    max_evidence_bytes: 32_768
  ]
  @stopwords ~w(the and for with from this that then when into before after only task)
  @type result :: %{
          receipt: map(),
          notes: [map()],
          evidence: map(),
          guards: [map()],
          exposure: Exposure.t() | nil
        }

  @doc "Pins sorted immutable ids for a frozen-library control or one updating task boundary."
  @spec freeze(store :: Lessons.t(), scope :: map(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def freeze(store, %{"id" => id} = scope, opts \\ []) when is_binary(id) and id != "" do
    with {:ok, limits} <- limits(opts),
         true <- json?(scope) and byte_size(JSON.encode!(scope)) <= 4096,
         {:ok, ids} <- Lessons.inventory(store),
         true <- valid_ids?(ids) and length(ids) <= limits[:max_entries] do
      {:ok, signed(%{"schema_version" => 1, "scope" => scope, "lesson_ids" => Enum.sort(ids)})}
    else
      false -> {:error, :lesson_inventory_limit}
      error -> error
    end
  end

  @doc "Returns a provider-free, content-free receipt of inclusion/exclusion decisions."
  @spec inspect(
          store :: Lessons.t(),
          library :: map(),
          query :: map(),
          binding :: map(),
          opts :: keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def inspect(store, library, query, binding, opts \\ []) do
    with {:ok, selection} <- select(store, library, query, binding, opts),
         do: {:ok, selection.receipt}
  end

  @doc "Commits exposure before releasing selected lesson notes and bounded evidence."
  @spec retrieve(
          store :: Lessons.t(),
          library :: map(),
          query :: map(),
          binding :: map(),
          consumer :: map(),
          commit :: (map(), Exposure.t() -> :ok | {:error, term()}),
          opts :: keyword()
        ) ::
          {:ok, result()} | {:error, term()}
  def retrieve(store, library, query, binding, consumer, commit, opts \\ [])
      when is_function(commit, 2) do
    with {:ok, selection} <- select(store, library, query, binding, opts),
         :ok <- complete(selection.receipt),
         {:ok, exposure} <- expose(selection, binding, consumer, commit) do
      {:ok,
       Map.take(selection, [:receipt, :notes, :evidence, :guards]) |> Map.put(:exposure, exposure)}
    end
  end

  defp select(store, library, query, binding, opts)
       when is_map(library) and is_map(query) and is_map(binding) do
    with {:ok, limits} <- limits(opts),
         true <- json?(binding) and byte_size(JSON.encode!(binding)) <= 8192,
         :ok <- library(library, limits),
         {:ok, terms} <- query_terms(query),
         {:ok, scan} <- scan(store, library, limits),
         {:ok, now} <- now(opts),
         {:ok, ranked, decisions} <- rank(scan.records, library["scope"], binding, terms, now) do
      chosen = choose(ranked, limits[:max_results])
      chosen_ids = Enum.map(chosen, & &1.lesson.id)
      decisions = Enum.map(decisions, &rank_decision(&1, chosen_ids))
      notes = Enum.map(chosen, &Evidence.note(&1.lesson, limits[:max_note_bytes]))

      with {:ok, files, guards} <-
             Evidence.materialize(Enum.map(chosen, & &1.lesson), limits[:max_evidence_bytes]) do
        content = %{"notes" => notes, "evidence" => files, "guards" => guards}

        receipt =
          receipt(library, query, binding, limits, scan, chosen, decisions, content)
          |> Map.put("at", DateTime.to_iso8601(now))
          |> Map.delete("sha256")
          |> signed()

        result(receipt, notes, files, guards, chosen)
      end
    else
      false -> {:error, :invalid_retrieval_binding}
      error -> error
    end
  end

  defp select(_store, _library, _query, _binding, _opts), do: {:error, :invalid_retrieval_input}

  defp now(opts) do
    case Keyword.get(opts, :now, DateTime.utc_now()) do
      %DateTime{} = now -> {:ok, now}
      _invalid -> {:error, :invalid_retrieval_time}
    end
  end

  defp result(receipt, notes, files, guards, chosen) do
    if byte_size(JSON.encode!(receipt)) <= 131_072 do
      {:ok,
       %{
         receipt: receipt,
         notes: notes,
         evidence: files,
         guards: guards,
         lessons: Enum.map(chosen, & &1.lesson)
       }}
    else
      {:error, :retrieval_receipt_limit}
    end
  end

  defp limits(opts) do
    values = Keyword.merge(@limits, Keyword.take(opts, Keyword.keys(@limits)))

    if Enum.all?(values, fn {_key, value} -> is_integer(value) and value > 0 end) and
         values[:max_entries] <= 10_000 and values[:max_results] <= 16 and
         values[:max_decisions] <= 128 and
         values[:max_source_bytes] <= 100 * 1024 * 1024 and
         values[:max_note_bytes] <= 4096 and values[:max_evidence_bytes] <= 262_144,
       do: {:ok, values},
       else: {:error, :invalid_retrieval_limits}
  end

  defp library(map, limits) do
    with true <- json?(map) and byte_size(JSON.encode!(map)) <= 1_048_576,
         :ok <- Contract.verify_version(map, "schema_version", 1),
         :ok <- Contract.verify_digest(map, "sha256"),
         true <- Enum.sort(Map.keys(map)) == ~w(lesson_ids schema_version scope sha256),
         %{"id" => id} when is_binary(id) and id != "" <- map["scope"],
         true <- byte_size(JSON.encode!(map["scope"])) <= 4096,
         true <-
           valid_ids?(map["lesson_ids"]) and length(map["lesson_ids"]) <= limits[:max_entries],
         true <- map["lesson_ids"] == Enum.sort(map["lesson_ids"]) do
      :ok
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_lesson_library}
    end
  end

  defp valid_ids?(ids) do
    is_list(ids) and Enum.uniq(ids) == ids and
      Enum.all?(ids, &(is_binary(&1) and Regex.match?(~r/\Alesson_[a-f0-9]{64}\z/, &1)))
  end

  defp query_terms(query) do
    task = query["task"]
    cues = Map.get(query, "failure_cues", [])

    if Enum.all?(Map.keys(query), &(&1 in ~w(task failure_cues))) and is_binary(task) and
         String.valid?(task) and
         is_list(cues) and Enum.all?(cues, &(is_binary(&1) and String.valid?(&1))) and
         byte_size(JSON.encode!(query)) <= 8192 do
      {:ok, words(Enum.join([task | cues], " ")) |> Enum.take(64)}
    else
      {:error, :invalid_retrieval_query}
    end
  end

  defp words(text) do
    Regex.scan(~r/[\p{L}\p{N}_]+/u, String.downcase(text))
    |> List.flatten()
    |> Enum.reject(&(String.length(&1) < 3 or byte_size(&1) > 64 or &1 in @stopwords))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scan(store, library, limits) do
    initial = %{records: [], bytes: 0, stop: nil}

    Enum.reduce_while(library["lesson_ids"], {:ok, initial}, fn id, {:ok, acc} ->
      remaining = limits[:max_source_bytes] - acc.bytes

      fetched =
        if remaining > 0,
          do: Lessons.fetch(store, id, remaining),
          else: {:error, :source_bytes_limit}

      collect(fetched, id, acc, remaining)
    end)
  end

  defp collect({:ok, record, bytes}, id, acc, remaining)
       when is_integer(bytes) and bytes >= 0 and bytes <= remaining do
    case valid_record(record, id) do
      :ok ->
        {:cont, {:ok, %{acc | records: [{id, record} | acc.records], bytes: acc.bytes + bytes}}}

      error ->
        {:halt, error}
    end
  end

  defp collect({:error, :source_bytes_limit}, _id, acc, _remaining),
    do: {:halt, {:ok, %{acc | stop: "source_bytes_limit"}}}

  defp collect({:error, reason}, id, acc, _remaining) when reason in [:enoent, :not_found],
    do: {:halt, {:ok, %{acc | records: [{id, :missing} | acc.records], stop: "missing_record"}}}

  defp collect({:error, _reason} = error, _id, _acc, _remaining), do: {:halt, error}
  defp collect(_invalid, _id, _acc, _remaining), do: {:halt, {:error, :invalid_lesson_fetch}}

  defp valid_record({:retained, %Lesson{id: id} = lesson}, id), do: Lesson.verify(lesson)

  defp valid_record({:pruned, %{"id" => id, "supersedes" => supersedes} = map}, id) do
    with true <- valid_ids?(supersedes),
         :ok <- Contract.verify_version(map, "schema_version", 1),
         :ok <- Contract.verify_digest(map, "sha256") do
      :ok
    else
      _invalid -> {:error, :invalid_lesson_fetch}
    end
  end

  defp valid_record(_record, _id), do: {:error, :invalid_lesson_fetch}

  defp rank(records, scope, binding, terms, now) do
    superseded = Enum.flat_map(records, fn {_id, record} -> supersedes(record) end)

    Enum.reduce_while(Enum.sort(records), {:ok, [], []}, fn {id, record},
                                                            {:ok, ranked, decisions} ->
      case qualify(record, scope, binding, terms, now, id in superseded) do
        {:ok, lesson, score, matches} ->
          row = %{lesson: lesson, score: score}
          {:cont, {:ok, [row | ranked], [decision(id, "eligible", score, matches) | decisions]}}

        {:exclude, reason} ->
          {:cont, {:ok, ranked, [decision(id, reason, 0, []) | decisions]}}

        error ->
          {:halt, error}
      end
    end)
    |> conflicts()
  end

  defp supersedes({:retained, lesson}), do: lesson.supersedes
  defp supersedes({:pruned, map}), do: map["supersedes"]
  defp supersedes(:missing), do: []
  defp qualify(:missing, _scope, _binding, _terms, _now, _superseded), do: {:exclude, "missing"}

  defp qualify({:pruned, %{"scope" => scope}}, scope, _binding, _terms, _now, _superseded),
    do: {:exclude, "pruned"}

  defp qualify(
         {:retained, %Lesson{scope: scope} = lesson},
         scope,
         binding,
         terms,
         now,
         superseded
       ) do
    with :ok <- Lesson.verify(lesson),
         false <- superseded,
         :ok <- Lesson.applicable(lesson, binding, now) do
      cues = words(Enum.join(lesson.applicability, " "))
      matches = Enum.filter(terms, &(&1 in cues))

      if matches == [],
        do: {:exclude, "applicability_mismatch"},
        else:
          {:ok, lesson,
           length(matches) * 4 + overlap(terms, lesson.mechanism) * 2 + overlap(terms, lesson.key),
           matches}
    else
      true ->
        {:exclude, "superseded"}

      {:error, {:binding_changed, _key}} ->
        {:exclude, "binding_changed"}

      {:error, reason} when reason in [:expired, :not_yet_created] ->
        {:exclude, Atom.to_string(reason)}

      error ->
        error
    end
  end

  defp qualify(_record, _scope, _binding, _terms, _now, _superseded),
    do: {:error, :lesson_scope_mismatch}

  defp overlap(terms, text) do
    words = Map.new(words(text), &{&1, true})
    Enum.count(terms, &Map.has_key?(words, &1))
  end

  defp conflicts({:ok, ranked, decisions}) do
    conflicts =
      ranked
      |> Enum.group_by(& &1.lesson.key)
      |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
      |> Enum.flat_map(fn {_key, group} -> Enum.map(group, & &1.lesson.id) end)

    {:ok, Enum.reject(ranked, &(&1.lesson.id in conflicts)),
     Enum.map(decisions, fn decision ->
       if decision["id"] in conflicts,
         do: Map.put(decision, "decision", "conflict"),
         else: decision
     end)}
  end

  defp conflicts(error), do: error

  defp choose(ranked, max_results) do
    sorted = Enum.sort_by(ranked, &{-&1.score, &1.lesson.id})

    case Enum.find(sorted, &(&1.lesson.outcome in ~w(rejected contradicted))) do
      nil ->
        Enum.take(sorted, max_results)

      negative ->
        [
          negative
          | Enum.reject(sorted, &(&1.lesson.id == negative.lesson.id))
            |> Enum.take(max_results - 1)
        ]
    end
  end

  defp decision(id, reason, score, matches),
    do: %{"id" => id, "decision" => reason, "score" => score, "matches" => matches}

  defp rank_decision(%{"decision" => "eligible", "id" => id} = row, chosen),
    do: Map.put(row, "decision", if(id in chosen, do: "selected", else: "rank_limit"))

  defp rank_decision(row, _chosen), do: row

  defp receipt(library, query, binding, limits, scan, chosen, decisions, files) do
    decisions = Enum.sort_by(decisions, & &1["id"])

    signed(%{
      "schema_version" => 1,
      "library_sha256" => library["sha256"],
      "scope" => library["scope"],
      "retriever" => "lemieux.lesson-retrieval/v1",
      "query_sha256" => Contract.digest(query),
      "binding_sha256" => Contract.digest(binding),
      "status" => if(scan.stop, do: "incomplete", else: "complete"),
      "stop_reason" => scan.stop,
      "limits" => Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end),
      "source_bytes" => scan.bytes,
      "scanned" => length(scan.records),
      "counts" => Enum.frequencies_by(decisions, & &1["decision"]),
      "decisions" => Enum.take(decisions, limits[:max_decisions]),
      "omitted_decisions" => max(length(decisions) - limits[:max_decisions], 0),
      "selected" => Enum.map(chosen, &%{"id" => &1.lesson.id, "sha256" => &1.lesson.sha256}),
      "evidence_sha256" => Contract.digest(files)
    })
  end

  defp complete(%{"status" => "complete"}), do: :ok
  defp complete(receipt), do: {:error, {:retrieval_incomplete, receipt}}
  defp expose(%{lessons: []}, _binding, _consumer, _commit), do: {:ok, nil}

  defp expose(selection, binding, consumer, commit) do
    attrs =
      consumer
      |> Map.take(~w(id consumer_role consumer_id lineage_id model experiment_id at))
      |> Map.merge(%{
        "context_digest" =>
          Contract.digest(%{"binding" => binding, "retrieval" => selection.receipt["sha256"]}),
        "direct_case_ids" => [],
        "derived_artifact_ids" => Enum.map(selection.lessons, & &1.id),
        "source_case_ids" =>
          selection.lessons |> Enum.flat_map(& &1.source_case_ids) |> Enum.uniq() |> Enum.sort()
      })

    with true <- is_binary(consumer["id"]) and is_binary(consumer["at"]),
         {:ok, exposure} <- Exposure.new(attrs),
         :ok <- commit.(selection.receipt["scope"], exposure) do
      {:ok, exposure}
    else
      false -> {:error, :invalid_lesson_consumer}
      {:error, reason} -> {:error, {:exposure_not_committed, reason}}
      _invalid -> {:error, :invalid_exposure_commit_result}
    end
  end

  defp signed(map), do: Map.put(map, "sha256", Contract.digest(map))
  defp json?(%_struct{}), do: false

  defp json?(map) when is_map(map),
    do:
      Enum.all?(map, fn {key, value} -> is_binary(key) and String.valid?(key) and json?(value) end)

  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)
end
