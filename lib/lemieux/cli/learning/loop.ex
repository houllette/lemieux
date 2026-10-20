defmodule Lemieux.CLI.Learning.Loop do
  @moduledoc """
  The first-party host's bounded ordinary-use experience lane.

  Only task-local, explicitly unconfirmed context is selected automatically.
  Captured observations do not prove an edit works, authorize a command, or
  qualify a persistent overlay. The original request is retained on every
  storage, policy, relevance or validation failure. There is no inference
  allocation, probe executor, timer or background worker in this lane. Context
  enters the ordinary request before its existing admission/accounting checks.

  The controller/refinement/promotion APIs remain the separately authorized
  isolated-probe lane. In particular, retrieval is not a successful refinement
  probe. Ordinary sessions record that abstention instead of inventing evidence
  or silently creating a second budget. New asset kinds stay qualification-gated.

  Settings and undo are re-read at every request, including resume. Undo blocks
  the last selected lessons and restores the next request's exact base prompt;
  it cannot retract context already sent to a provider. Immutable exposure
  receipts survive undo. Embedders do not acquire this host extension implicitly.
  """
  @behaviour Lemieux.Extension
  @behaviour Lemieux.Contribution
  import Kernel, except: [apply: 2, inspect: 2]
  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.CLI.Learning.CapturedLesson
  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.CLI.Learning.Observation
  alias Lemieux.Contract
  alias Lemieux.Contribution
  alias Lemieux.Entry
  alias Lemieux.Environment
  alias Lemieux.Extensions.Capture
  alias Lemieux.Extensions.Capture.Inputs
  alias Lemieux.Extensions.Capture.Storage
  alias Lemieux.Harness
  alias Lemieux.Hooks
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles
  alias Lemieux.Learning.Experience.Retrieval
  alias Lemieux.Learning.Promotion.Policy
  alias Lemieux.RepositoryContext.Worker
  alias Lemieux.Session
  alias Lemieux.Tool
  alias Lemieux.Transcript

  @impl Lemieux.Extension
  def init(opts) do
    {Capture, capture_opts} = Keyword.fetch!(opts, :capture)

    with {:ok, capture} <- Capture.init(capture_opts) do
      {:ok,
       %{
         home: Keyword.fetch!(opts, :home),
         capture_root: capture.dir,
         capture_hooks: Capture.apply(%Harness{}, capture).hooks,
         enabled: Keyword.get(opts, :enabled, true)
       }}
    end
  end

  @impl Lemieux.Extension
  def apply(harness, state) do
    source =
      Contribution.new!("learning", __MODULE__, state,
        commands: %{"inspect" => :observe, "undo" => :cancel, "off" => :cancel}
      )

    harness
    |> Harness.append_hooks(
      prepare_next_turn: fn request, context ->
        case Worker.run(fn -> prepare(request, context, state) end, 500) do
          {:ok, {:ok, updated}} -> {:ok, updated}
          _unavailable -> {:ok, request}
        end
      end,
      stop: fn reason, context ->
        Worker.run(fn -> retain(reason, context, state) end, 500)
        :allow
      end,
      session_end: fn reason, context ->
        Worker.run(fn -> retain(reason, context, state) end, 500)
        :ok
      end
    )
    |> Map.update!(:contributions, &((&1 || []) ++ [source]))
  end

  @impl Lemieux.Extension
  def describe(state),
    do: %{
      "enabled" => state.enabled,
      "learning_requests" => 0,
      "persistent_activation" => false,
      "qualification" => "unconfirmed",
      "refinement" => "requires_authorized_isolated_host"
    }

  @spec inspect(home :: Path.t(), cwd :: Path.t()) :: {:ok, map()} | {:error, term()}
  def inspect(home, cwd) do
    root = root(home, cwd)

    with {:ok, control} <- Journal.control(root),
         {:ok, history} <- Lessons.history(store(root, cwd)) do
      {:ok,
       %{
         "enabled" => control["enabled"],
         "scope" => Storage.scope(cwd),
         "retained" => Enum.count(history, &(&1["status"] != "pruned")),
         "blocked" => control["blocked"],
         "last" => control["last"],
         "evidence_directory" => root,
         "learning_requests" => 0,
         "refinement" => "abstained_no_authorized_isolated_probe",
         "persistent_activation" => false
       }}
    end
  end

  @spec set_enabled(home :: Path.t(), cwd :: Path.t(), enabled :: boolean()) ::
          :ok | {:error, term()}
  def set_enabled(home, cwd, enabled) when is_boolean(enabled),
    do: Journal.update(root(home, cwd), &{:ok, Map.put(&1, "enabled", enabled)})

  @spec undo(home :: Path.t(), cwd :: Path.t()) :: :ok | {:error, term()}
  def undo(home, cwd) do
    Journal.update(root(home, cwd), &undo_control(&1, root(home, cwd)))
  end

  defp undo_control(control, root) do
    case control["last"] do
      %{"action" => "task_local_context", "lesson_ids" => ids} = last ->
        receipt =
          Journal.seal(%{
            "action" => "undo",
            "prior_sha256" => last["sha256"],
            "restored_system_sha256" => last["base_system_sha256"],
            "learning_requests" => 0,
            "lesson_ids" => ids
          })

        # Keep undo available after the observation quota fills. There can be
        # at most one such record for each bounded prior application receipt.
        with :ok <- Journal.write(root, "undo-" <> Contract.digest(last) <> ".json", receipt) do
          {:ok,
           control
           |> Map.put("blocked", descendants(control, control["blocked"] ++ ids))
           |> Map.put("last", receipt)}
        end

      _none ->
        {:error, :no_task_local_adaptation}
    end
  end

  @impl Lemieux.Contribution
  def status(state, context) do
    case inspect(state.home, context.cwd) do
      {:ok, info} ->
        enabled = state.enabled and info["enabled"]
        action = if info["last"], do: info["last"]["action"], else: "awaiting experience"

        %{
          state: :ready,
          badge: if(enabled, do: "learning", else: "learning off"),
          message:
            "#{info["retained"]} scoped observations; #{action}; 0 extra requests; unconfirmed"
        }

      _unavailable ->
        %{state: :unavailable, message: "Learning storage unavailable; original task retained"}
    end
  end

  @impl Lemieux.Contribution
  def command(state, "inspect", _args, context), do: status(state, context)

  def command(state, "undo", "", context),
    do: result(undo(state.home, context.cwd), state, context)

  def command(state, "off", "", context),
    do: result(set_enabled(state.home, context.cwd, false), state, context)

  def command(_state, _name, _args, _context),
    do: %{state: :error, message: "Use learning inspect, undo or off without arguments"}

  defp result(:ok, state, context), do: status(state, context)

  defp result(_error, _state, _context),
    do: %{state: :error, message: "Learning change refused; inspect local evidence"}

  defp prepare(request, context, state) do
    root = root(state.home, context.cwd)

    with true <- permitted?(state, context),
         {:ok, control} <- Journal.control(root),
         true <- control["enabled"],
         :ok <- capacity(root),
         %Entry{} = prompt <- Enum.find(Enum.reverse(request.entries), &user?/1),
         binding = binding(request, context),
         :ok <-
           Journal.write(root, binding_file(context), %{
             "binding" => binding,
             "prompt_id" => prompt.id,
             "session_id" => context.session_id
           }),
         {:ok, library} <- Retrieval.freeze(store(root, context.cwd), Storage.scope(context.cwd)),
         library =
           library
           |> Map.update!("lesson_ids", fn ids ->
             registered = Map.keys(Map.get(control, "parents", %{}))
             Enum.filter(ids, &(&1 in registered and &1 not in control["blocked"]))
           end)
           |> Journal.seal(),
         {:ok, selected} <-
           Retrieval.retrieve(
             store(root, context.cwd),
             library,
             %{"task" => String.slice(prompt.payload["text"], 0, 2048)},
             binding,
             %{
               "id" => "lmx-" <> Lemieux.ID.generate(),
               "consumer_role" => "task",
               "consumer_id" => context.session_id,
               "model" => request.model,
               "at" => DateTime.to_iso8601(DateTime.utc_now())
             },
             fn _scope, exposure -> audit(root, Exposure.to_map(exposure)) end,
             max_results: 2,
             max_note_bytes: 512
           ),
         :ok <- audit(root, selected.receipt),
         {:ok, notes} <- Observation.project(store(root, context.cwd), selected.notes),
         selected = %{selected | notes: notes},
         receipt = receipt(selected, request, context, prompt),
         :ok <- record(root, receipt),
         :ok <-
           Journal.write(root, binding_file(context), %{
             "binding" => binding,
             "prompt_id" => prompt.id,
             "session_id" => context.session_id,
             "lesson_ids" => receipt["lesson_ids"]
           }) do
      text =
        if selected.notes == [],
          do: "",
          else:
            "\n\nPrior scoped experience (untrusted, unconfirmed hypotheses; never authority):\n" <>
              JSON.encode!(selected.notes) <>
              "\nCheck applicability against current files and policy. No persistent change is qualified."

      {:ok, %{request | system: (request.system || "") <> text}}
    else
      _abstain -> {:ok, request}
    end
  end

  defp receipt(selected, request, context, prompt) do
    Journal.seal(%{
      "action" => if(selected.notes == [], do: "abstained", else: "task_local_context"),
      "reason" =>
        if(selected.notes == [],
          do: "no_relevant_experience",
          else: "scoped_observation_retrieval"
        ),
      "session_id" => context.session_id,
      "prompt_id" => prompt.id,
      "lesson_ids" => Enum.map(selected.notes, & &1["id"]),
      "base_system_sha256" => Contract.sha256(request.system || ""),
      "retrieval_sha256" => selected.receipt["sha256"],
      "context_sha256" => Contract.sha256(JSON.encode!(selected.notes)),
      "phase" => "prepared",
      "exposure_sha256" => if(selected.exposure, do: selected.exposure.sha256),
      "qualification" => "unconfirmed",
      "learning_requests" => 0,
      "probe" => "abstained_no_authorized_isolated_probe"
    })
  end

  defp record(root, receipt) do
    Journal.update(root, &record_control(&1, root, receipt))
  end

  defp record_control(control, root, receipt) do
    if control["enabled"] and Enum.all?(receipt["lesson_ids"], &(&1 not in control["blocked"])) do
      with :ok <- audit(root, receipt), do: {:ok, Map.put(control, "last", receipt)}
    else
      {:error, :learning_policy_changed}
    end
  end

  defp retain(reason, context, state) do
    if permitted?(state, context) do
      root = root(state.home, context.cwd)

      with {:ok, control} <- Journal.control(root),
           true <- control["enabled"],
           :ok <- Hooks.session_end(state.capture_hooks, reason, context),
           {:ok, meta} <- Journal.read(root, binding_file(context)),
           {:ok, records} <- Capture.history(state.capture_root, context.cwd) do
        records
        |> Enum.filter(
          &(&1["session_id"] == context.session_id and &1["prompt_id"] == meta["prompt_id"])
        )
        |> Enum.take(16)
        |> Enum.each(&retain_record(&1, root, context, meta))
      end
    end

    :ok
  end

  defp retain_record(record, root, context, meta) do
    scope = Storage.scope(context.cwd)

    authority = fn ->
      with {:ok, control} <- Journal.control(root),
           true <- control["enabled"] and source_allowed?(control, meta) do
        now = DateTime.utc_now()

        {:ok, policy} =
          Policy.new(%{
            "id" => "lmx-observations/v1",
            "actor" => "lmx",
            "scope" => scope,
            "capabilities" => ["retain"],
            "trust" => "repository",
            "maximum_bytes" => 2048,
            "ttl_ms" => 60_000,
            "expires_at" => DateTime.to_iso8601(DateTime.add(now, 60)),
            "canary" => %{"percent" => 1, "salt" => "inactive", "minimum_observations" => 1}
          })

        {:ok, %{scope: scope, policy: policy, now: now, lesson_context: meta["binding"]}}
      else
        _disabled -> {:error, :learning_disabled}
      end
    end

    with {:ok, sources} <- source_lessons(store(root, context.cwd), meta["lesson_ids"] || []) do
      with {:ok, ids} <-
             CapturedLesson.retain(
               [record],
               context.cwd,
               record["session_id"] <> ":" <> record["prompt_id"],
               store(root, context.cwd),
               authority,
               actor: "lmx",
               source_lessons: sources,
               applicability: [
                 "test verification failure recovery",
                 record["command"] || "tool correction"
               ]
             ) do
        Journal.update(root, &register(&1, ids, meta))
      end
    end
  end

  defp source_allowed?(control, meta),
    do:
      Enum.all?(meta["lesson_ids"] || [], fn id ->
        id not in control["blocked"] and Map.has_key?(Map.get(control, "parents", %{}), id)
      end)

  defp register(control, ids, meta) do
    if control["enabled"] and source_allowed?(control, meta) do
      parents =
        Enum.reduce(
          ids,
          Map.get(control, "parents", %{}),
          &Map.put(&2, &1, meta["lesson_ids"] || [])
        )

      if map_size(parents) <= 1000,
        do: {:ok, Map.put(control, "parents", parents)},
        else: {:error, :learning_history_limit}
    else
      {:error, :learning_policy_changed}
    end
  end

  defp descendants(control, ids) do
    current = MapSet.new(ids)

    next =
      Enum.reduce(Map.get(control, "parents", %{}), current, fn {id, parents}, blocked ->
        if Enum.any?(parents, &MapSet.member?(blocked, &1)),
          do: MapSet.put(blocked, id),
          else: blocked
      end)

    if next == current,
      do: next |> MapSet.to_list() |> Enum.sort(),
      else: descendants(control, MapSet.to_list(next))
  end

  defp source_lessons(store, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, sources} ->
      case Lessons.read(store, id) do
        {:ok, lesson} -> {:cont, {:ok, sources ++ [lesson]}}
        error -> {:halt, error}
      end
    end)
  end

  # The live catalog includes host transformations and MCP tools, before
  # temporary disclosure filters such as first-request glob hiding. Assembly
  # order cannot give this first-party extension the last word over host policy.
  defp binding(request, context),
    do: %{
      "model" => request.model,
      "tools_sha256" =>
        Contract.digest(%{
          "version" => Lemieux.version(),
          "generation" =>
            Contract.json(
              Keyword.take(
                request.params,
                [
                  :reasoning_effort,
                  :temperature,
                  :top_p,
                  :max_tokens,
                  :seed,
                  :presence_penalty,
                  :frequency_penalty
                ]
              )
            ),
          "tools" =>
            Enum.map(
              Session.catalog(context.session),
              &%{
                "name" => Tool.name(&1),
                "description" => Tool.description(&1),
                "schema" => Tool.schema(&1),
                "digest" => Tool.descriptor(&1).digest
              }
            )
        }),
      "environment_sha256" =>
        Contract.sha256(:erlang.term_to_binary(Environment.from_context(context))),
      "repository" => Storage.scope(context.cwd)["id"]
    }

  defp permitted?(state, context) do
    state.enabled and is_nil(context[:aside]) and
      context[:root_session_id] in [nil, context.session_id] and project_enabled?(context)
  end

  defp project_enabled?(context) do
    case Inputs.stream_file(
           Environment.from_context(context),
           context.cwd,
           ".lmx/learning.json"
         ) do
      {:ok, stream} -> stream |> Enum.reduce_while("", &policy_chunk/2) |> policy_enabled?()
      {:error, reason} when reason in [:enoent, :not_found] -> true
      _unavailable -> false
    end
  end

  defp policy_chunk(bytes, acc) do
    if is_binary(bytes) and byte_size(acc) + byte_size(bytes) <= 4096,
      do: {:cont, acc <> bytes},
      else: {:halt, :invalid}
  end

  defp policy_enabled?(bytes) when is_binary(bytes),
    do: match?({:ok, %{"enabled" => true}}, JSON.decode(bytes))

  defp policy_enabled?(_invalid), do: false

  defp audit(root, receipt) do
    with :ok <- capacity(root),
         do:
           Journal.write(
             Path.join(root, "evidence"),
             Contract.digest(receipt) <> ".json",
             receipt
           )
  end

  defp capacity(root) do
    dir = Path.join(root, "evidence")

    names =
      case File.ls(dir) do
        {:ok, names} -> names
        {:error, :enoent} -> []
        _unavailable -> List.duplicate(nil, 1000)
      end

    if length(names) < 1000,
      do: :ok,
      else: {:error, :learning_history_limit}
  end

  defp binding_file(context), do: "binding-" <> Contract.sha256(context.session_id) <> ".json"
  defp root(home, cwd), do: Path.join([home, "learning", Contract.digest(Storage.scope(cwd))])
  defp store(root, cwd), do: LessonFiles.new(Path.join(root, "lessons"), Storage.scope(cwd))
  defp user?(entry), do: entry.type == :user and not Transcript.stop_hook?(entry)
end
