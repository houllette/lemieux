defmodule Lemieux.Extensions.Capture do
  @moduledoc """
  Bounded, provider-free drafts from ordinary session failures and recoveries.

  The host selects this extension, its transcript store and private directory.
  The core starts no capture process. Before a prompt's first request it saves
  bounded workspace inputs through the current environment. Retries reuse that
  checkpoint; a resumed prompt with prior tool results cannot replace a missing
  original input with an already repaired workspace.

  Terminal capture reads authoritative entries, including explicit verification
  documents, rather than assuming best-effort tool callbacks saw every outcome.
  A passing command is an observed recovery, never proof of overall correctness.
  Corrections remain review drafts. Inputs with omissions, unavailable artifacts
  or no independent replay check are ineligible for corpus promotion.

  `validate_replay/3` requires an explicit host-supplied local validator. Merely
  loading a record never executes its command, restores authority or calls a
  model. The validator must run the exact check in appropriate host-owned
  isolation; a fork or directory copy alone does not isolate external effects.
  Capture itself never replays a command. `case_draft/3` retains the existing
  human corpus-promotion lane after that check.

  Storage is scoped to the host/project, private and ignored. Defaults retain
  at most 128 records for 30 days, each with at most 256 KiB of workspace bytes.
  Disable personal capture in the host configuration, or put
  `{"enabled": false}` in `.lmx/capture.json`. The project file can only opt
  out. `prune/4` and `forget/2` explicitly remove retained content. Snapshots
  exclude credential-shaped names; arbitrary source content still needs review.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]
  require Logger
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Environment
  alias Lemieux.Extensions.Capture.Inputs
  alias Lemieux.Extensions.Capture.Signals
  alias Lemieux.Extensions.Capture.Storage
  alias Lemieux.Feedback
  alias Lemieux.Feedback.CaseDraft
  alias Lemieux.Harness
  alias Lemieux.Hooks
  alias Lemieux.RepositoryContext.Worker
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tools.Read
  alias Lemieux.Transcript

  @impl true
  def init(opts) do
    values =
      Map.new(
        Keyword.merge(
          [
            max_input_bytes: 262_144,
            max_file_bytes: 65_536,
            max_files: 128,
            timeout_ms: 250,
            retention_days: 30,
            max_records: 128,
            max_source_bytes: 4_194_304,
            verification_commands: []
          ],
          opts
        )
      )

    with true <- is_binary(values[:dir]) and values[:dir] != "" and Map.has_key?(values, :store),
         true <-
           Enum.all?(
             ~w(max_input_bytes max_file_bytes max_files timeout_ms retention_days max_records max_source_bytes)a,
             &(is_integer(values[&1]) and values[&1] > 0)
           ),
         true <- valid_limits?(values),
         true <- valid_commands?(values.verification_commands) do
      {:ok, Map.update!(values, :dir, &Path.expand/1)}
    else
      _invalid -> {:error, :invalid_capture_configuration}
    end
  end

  defp valid_limits?(values) do
    maxima = %{
      max_input_bytes: 1_048_576,
      max_files: 512,
      timeout_ms: 2000,
      max_records: 1000,
      retention_days: 3650,
      max_source_bytes: 8_388_608
    }

    Enum.all?(maxima, fn {key, maximum} -> values[key] <= maximum end) and
      values.max_file_bytes <= values.max_input_bytes
  end

  defp valid_commands?(commands) when is_list(commands) and length(commands) <= 32,
    do: Enum.all?(commands, &(is_binary(&1) and byte_size(&1) in 1..4096))

  defp valid_commands?(_invalid), do: false

  @impl true
  def apply(harness, state) do
    state = Map.put(state, :hooks, harness.hooks || [])

    Harness.append_hooks(harness,
      prepare_next_turn: fn request, context ->
        observe(fn -> observe_checkpoint(request, context, state) end, state.timeout_ms)
        {:ok, request}
      end,
      session_end: fn _reason, context ->
        observe(fn -> observe_terminal(context, state) end, state.timeout_ms)
      end
    )
  end

  @impl true
  def describe(state),
    do:
      Map.take(
        state,
        ~w(max_input_bytes max_file_bytes max_files timeout_ms retention_days max_records)a
      )
      |> Contract.json()

  # The existing bounded worker also kills its child if the hook caller dies.
  # Untrusted environment/store callbacks cannot stall or crash completion.
  defp observe(work, timeout) do
    case Worker.run(work, timeout) do
      {:ok, :ok} -> :ok
      _unavailable -> reported({:error, :capture_unavailable})
    end
  end

  defp observe_checkpoint(request, context, state) do
    if enabled?(context) do
      case Enum.find(Enum.reverse(request.entries), &user?/1) do
        nil -> :ok
        prompt -> checkpoint(request, context, prompt, state) |> reported()
      end
    end

    :ok
  end

  defp checkpoint(request, context, prompt, state) do
    scope = Storage.scope(context.cwd)
    name = input_name(context.session_id, prompt.id)

    case Storage.read(state.dir, scope, name) do
      {:ok, _existing} ->
        :ok

      {:error, :enoent} ->
        attempted = Enum.any?(request.entries, &(&1.seq > prompt.seq and &1.type == :tool_result))

        input =
          if attempted,
            do: unavailable("prior_effects_without_checkpoint"),
            else:
              Inputs.capture(
                Environment.from_context(context),
                context.cwd,
                Map.put(state, :authorize, &authorized?(state, context, &1))
              )

        base = %{
          "version" => 1,
          "scope" => scope,
          "prompt_id" => prompt.id,
          "session_id" => context.session_id,
          "created_at" => DateTime.to_iso8601(prompt.at),
          "inputs" => input
        }

        with :ok <- Storage.write(state.dir, scope, name, signed(base)),
             do: Storage.prune_inputs(state.dir, scope, state.retention_days, state.max_records)

      error ->
        error
    end
  end

  defp authorized?(state, context, path) do
    args = %{"path" => path}
    call = %{id: "capture-input-" <> Contract.sha256(path), name: "read", arguments: args}

    policy_context =
      context
      |> Map.put(:call_id, call.id)
      |> Map.put(:approval_mode, :deny)
      |> Map.put(:tool_descriptor, Read |> Tool.descriptor() |> Descriptor.to_map())

    Hooks.before_tool_call(Map.get(context, :hooks, state.hooks), call, policy_context) ==
      {:ok, args}
  end

  defp observe_terminal(context, state) do
    if enabled?(context) do
      with {:ok, entries} <- source(state, context.session_id),
           :ok <- retain_signals(entries, context, state) do
        :ok
      else
        error -> reported(error)
      end
    end

    :ok
  end

  defp source(%{store: {JSONL, %{dir: dir}}} = state, id) do
    with true <- Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id),
         path = Path.join(dir, id <> ".jsonl"),
         {:ok, %{type: :regular, size: size}} when size <= state.max_source_bytes <-
           File.lstat(path) do
      read_source(state, id)
    else
      _unavailable -> {:error, :capture_source_limit_or_unavailable}
    end
  end

  defp source(state, id), do: read_source(state, id)

  defp read_source(state, id) do
    with {:ok, entries} <- Store.read(state.store, id),
         true <- length(entries) <= 5000,
         true <-
           Enum.reduce(entries, 0, &(byte_size(Entry.encode!(&1)) + &2)) <= state.max_source_bytes do
      {:ok, entries}
    else
      _unavailable -> {:error, :capture_source_limit_or_unavailable}
    end
  end

  defp retain_signals(entries, context, state) do
    scope = Storage.scope(context.cwd)

    {:ok, existing} = Storage.history(state.dir, scope)

    result =
      entries
      |> Signals.detect(state.verification_commands)
      |> Enum.reduce_while(:ok, fn signal, :ok ->
        duplicate =
          Enum.any?(
            existing,
            &(Map.take(&1, ~w(session_id kind entry_ids)) ==
                Map.put(Map.take(signal, ~w(kind entry_ids)), "session_id", context.session_id))
          )

        result =
          if duplicate,
            do: :ok,
            else: retain(state.dir, record(signal, entries, context, state, scope, existing))

        case result do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    inputs = entries |> Enum.filter(&user?/1) |> Enum.map(&input_name(context.session_id, &1.id))
    Storage.cleanup(state.dir, scope, inputs)

    with :ok <- result,
         do:
           Storage.prune(
             state.dir,
             scope,
             state.retention_days,
             state.max_records,
             DateTime.utc_now()
           )
  end

  defp record(signal, entries, context, state, scope, existing) do
    inputs =
      case Storage.read(state.dir, scope, input_name(context.session_id, signal["prompt_id"])) do
        {:ok, checkpoint} ->
          checkpoint["inputs"]

        _missing ->
          prior =
            Enum.find(
              existing,
              &(&1["session_id"] == context.session_id and &1["prompt_id"] == signal["prompt_id"])
            )

          if prior, do: prior["inputs"], else: unavailable("checkpoint_unavailable")
      end

    index = Map.new(entries, &{&1.id, &1})
    last_seq = Enum.max(Enum.map(signal["entry_ids"], &index[&1].seq))
    terminal = Enum.find(entries, &(&1.type == :run_evidence and &1.seq > last_seq))

    base =
      Map.merge(signal, %{
        "schema_version" => 1,
        "scope" => scope,
        "session_id" => context.session_id,
        "created_at" => DateTime.to_iso8601(index[hd(signal["entry_ids"])].at),
        "source_sha256" =>
          Contract.digest(%{
            "entries" =>
              Enum.map(signal["entry_ids"], &(index[&1] |> Entry.encode!() |> JSON.decode!()))
          }),
        "qualification" =>
          if(signal["command"], do: "mechanical_observation", else: "needs_review"),
        "task_correctness" => "unassessed",
        "status" => "draft",
        "inputs" => inputs,
        "terminal" =>
          if(terminal,
            do: Map.take(terminal.payload, ~w(id sha256 outcome stop_reason harness_snapshot)),
            else: %{"outcome" => "unavailable"}
          ),
        "replay" => %{"eligible" => false, "state" => "unverified"}
      })

    hash = Contract.digest(base)
    base |> Map.put("id", "capture_" <> hash) |> signed()
  end

  defp unavailable(reason),
    do:
      signed(%{
        "version" => 1,
        "files" => [],
        "size_bytes" => 0,
        "complete" => false,
        "skipped" => [%{"path" => ".", "reason" => reason}]
      })

  defp user?(entry), do: entry.type == :user and not Transcript.stop_hook?(entry)

  defp input_name(session, prompt),
    do: "input_" <> Contract.digest(%{"session" => session, "prompt" => prompt}) <> ".json"

  defp enabled?(context) do
    root = context[:root_session_id]
    top = (is_nil(root) or root == context.session_id) and is_nil(context[:aside])

    top and policy_enabled?(policy(context))
  end

  defp policy_enabled?({:ok, bytes}) when byte_size(bytes) <= 4096,
    do: project_enabled?(JSON.decode(bytes))

  defp policy_enabled?({:error, reason}) when reason in [:enoent, :not_found], do: true
  defp policy_enabled?(_invalid_or_unavailable), do: false

  # Environment.stream_file/3 otherwise falls back to an unbounded read.
  # Capture requires streaming instead of allocating an arbitrary policy file.
  defp policy(context) do
    with {:ok, stream} <-
           Inputs.stream_file(Environment.from_context(context), context.cwd, ".lmx/capture.json") do
      Enum.reduce_while(stream, {:ok, ""}, &policy_chunk/2)
    end
  end

  defp policy_chunk(bytes, {:ok, previous}) do
    if byte_size(bytes) + byte_size(previous) <= 4096,
      do: {:cont, {:ok, previous <> bytes}},
      else: {:halt, {:error, :policy_limit}}
  end

  defp project_enabled?({:ok, %{"enabled" => true}}), do: true
  defp project_enabled?(_disabled_or_invalid), do: false
  defp reported(:ok), do: :ok

  defp reported(_error),
    do: Logger.warning("lmx capture: evidence unavailable; no draft was qualified")

  defp signed(map), do: Map.put(map, "sha256", Contract.digest(map))

  @doc "Reads private capture drafts for this host/project; never feeds a model."
  @spec history(root :: Path.t(), cwd :: Path.t()) :: {:ok, [map()]} | {:error, term()}
  def history(root, cwd), do: Storage.history(root, Storage.scope(cwd))

  @doc "Idempotently retains a verified immutable capture record."
  @spec retain(root :: Path.t(), record :: map()) :: :ok | {:error, term()}
  def retain(root, record) do
    with :ok <- verify(record),
         do: Storage.write(root, record["scope"], record["id"] <> ".json", record)
  end

  @doc "Verifies capture identity and complete input bytes without restoring authority."
  @spec verify(record :: map()) :: :ok | {:error, term()}
  def verify(
        %{
          "schema_version" => 1,
          "scope" => %{"id" => scope},
          "id" => id,
          "created_at" => at,
          "inputs" => inputs,
          "entry_ids" => ids,
          "observations" => observations
        } = record
      )
      when is_binary(scope) and is_binary(id) and is_binary(at) and is_list(ids) and
             is_list(observations) do
    with :ok <- Contract.verify_digest(record, "sha256"),
         :ok <- Inputs.verify(inputs),
         true <- id == "capture_" <> Contract.digest(Map.drop(record, ~w(id sha256))),
         {:ok, _time, 0} <- DateTime.from_iso8601(at),
         true <- length(ids) in 1..32 and Enum.all?(ids, &is_binary/1),
         true <-
           record["kind"] in ~w(verification_failure verification_recovery correction repeated_tool_failure tool_recovery),
         true <- length(observations) <= 32,
         true <- record["task_correctness"] == "unassessed" and record["status"] == "draft",
         true <- record["qualification"] in ~w(mechanical_observation needs_review),
         true <- valid_replay?(record) do
      :ok
    else
      _invalid -> {:error, :invalid_capture_record}
    end
  end

  def verify(_invalid), do: {:error, :invalid_capture_record}

  defp valid_replay?(%{"replay" => %{"eligible" => false, "state" => "unverified"}}), do: true

  defp valid_replay?(%{
         "replay" => %{
           "eligible" => true,
           "state" => "reproduced_failure",
           "exit_status" => status,
           "input_sha256" => sha
         },
         "inputs" => %{"complete" => true, "sha256" => sha},
         "command" => command,
         "observations" => [%{"exit_status" => status} | _]
       })
       when is_binary(command) and is_integer(status) and status > 0, do: true

  defp valid_replay?(_invalid), do: false

  @doc "Materializes verified pre-effect inputs into a new host-owned directory. Executes nothing."
  @spec materialize(record :: map(), destination :: Path.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def materialize(record, destination) do
    with :ok <- verify(record),
         :ok <- Storage.ancestors(Path.expand(destination)),
         do: Inputs.materialize(record["inputs"], destination)
  end

  @doc "Explicitly validates replay in host-supplied isolation; corrections and incomplete inputs stay ineligible."
  @spec validate_replay(
          record :: map(),
          destination :: Path.t(),
          validator :: (Path.t(), String.t() -> {:ok, non_neg_integer()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def validate_replay(record, destination, validator) when is_function(validator, 2) do
    with :ok <- verify(record),
         true <- record["inputs"]["complete"] and is_binary(record["command"]),
         {:ok, path} <- materialize(record, destination),
         {:ok, status} when is_integer(status) and status > 0 <-
           validator.(path, record["command"]),
         true <- status == hd(record["observations"])["exit_status"] do
      base =
        record
        |> Map.drop(~w(id sha256))
        |> Map.put("replay", %{
          "eligible" => true,
          "state" => "reproduced_failure",
          "exit_status" => status,
          "input_sha256" => record["inputs"]["sha256"]
        })

      {:ok, base |> Map.put("id", "capture_" <> Contract.digest(base)) |> signed()}
    else
      _ineligible -> {:error, :capture_replay_ineligible}
    end
  end

  @doc "Creates an ordinary reviewable corpus draft only after explicit failure reproduction."
  @spec case_draft(record :: map(), destination :: Path.t(), opts :: keyword()) ::
          {:ok, CaseDraft.t()} | {:error, term()}
  def case_draft(record, destination, opts \\ []) do
    with :ok <- verify(record),
         true <- record["replay"]["eligible"] == true and is_binary(record["command"]),
         {:ok, input} <- materialize(record, destination <> ".input"),
         {:ok, feedback} <-
           Feedback.new(
             "Captured verification failure requiring review.",
             %{
               "host" => "lemieux.capture",
               "tenant_id" => "local",
               "project_id" => record["scope"]["id"],
               "session_id" => record["session_id"],
               "entry_id" => hd(record["entry_ids"])
             },
             actor: %{"type" => "system", "id" => "lemieux.capture"},
             type: :bug,
             verifiability: %{"class" => "mechanical", "source" => "capture_replay"}
           ),
         result <-
           CaseDraft.create(
             feedback,
             input,
             destination,
             Keyword.merge(
               [
                 prompt: "Repair the recorded verification failure.",
                 verifier: ["sh", "-c", record["command"]]
               ],
               Keyword.take(opts, [:prompt, :id])
             )
           ) do
      File.rm_rf(input)
      result
    else
      _ineligible -> {:error, :capture_replay_ineligible}
    end
  end

  @doc "Enforces explicit finite per-project retention without invoking a provider."
  @spec prune(
          root :: Path.t(),
          cwd :: Path.t(),
          days :: pos_integer(),
          max_records :: pos_integer()
        ) :: :ok | {:error, term()}
  def prune(root, cwd, days, max_records) when days in 1..3650 and max_records in 1..1000,
    do: Storage.prune(root, Storage.scope(cwd), days, max_records, DateTime.utc_now())

  @doc "Explicitly removes this project's capture content, including pending checkpoints."
  @spec forget(root :: Path.t(), cwd :: Path.t()) :: :ok | {:error, term()}
  def forget(root, cwd) do
    dir = Storage.directory(root, Storage.scope(cwd))
    with :ok <- Storage.ancestors(dir), {:ok, _removed} <- File.rm_rf(dir), do: :ok
  end
end
