defmodule Lemieux.Agent.Checkpoint do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Checkpoints for ordinary Elixir agent composition, not a workflow language.

  A host opens a run with code/configuration/policy identity, then calls `step/5`
  around bounded `Lemieux.Agent.Session` runs or deterministic work. Each step
  binds its input workspace snapshot and upstream artifact digests. Independent
  steps use separate CAS documents, so bounded fan-out has no shared writer race.

  An intent is committed before calling code. Interruption leaves `in_doubt`;
  resume never blindly repeats an external effect. The host inspects receipts
  and explicitly resolves it or authorizes a retry. Completed output is reused
  only with an explicit successful `:validate` callback. Identity equality alone
  cannot prove that a previous file edit or external effect is still present.

  `approval: true` suspends before execution. Host approval binds the observed
  revision and exact step digest. Changed input requires a new step key/run.
  Forks cannot inherit executable run identity; start a new run in the fork.
  Documents contain only bounded JSON data. Functions, credentials, sandbox
  authority and admission policy must be rebound by the host on every resume.
  """
  alias Lemieux.Contract
  alias Lemieux.Session
  alias Lemieux.Session.Document

  @enforce_keys [:session, :run_id, :identity, :namespace]
  defstruct [:session, :run_id, :identity, :namespace]

  @type t :: %__MODULE__{
          session: Session.session(),
          run_id: String.t(),
          identity: map(),
          namespace: String.t()
        }

  @doc "Opens a session-bound run, refusing changed code, configuration or policy."
  @spec open(session :: Session.session(), run_id :: String.t(), identity :: map()) ::
          {:ok, t()} | {:error, term()}
  def open(session, run_id, identity)
      when is_binary(run_id) and byte_size(run_id) in 1..128 and is_map(identity) do
    handle = %__MODULE__{
      session: session,
      run_id: run_id,
      identity: identity,
      namespace: "flow.run." <> Contract.sha256(run_id)
    }

    expected = %{
      "version" => 1,
      "run_id" => run_id,
      "session_id" => Session.id(session),
      "identity" => identity
    }

    with :ok <- valid_identity(identity),
         {:ok, document} <- Session.document(session, handle.namespace) do
      open_document(handle, expected, document)
    end
  end

  def open(_session, _run_id, _identity), do: {:error, :invalid_run_identity}

  defp open_document(handle, expected, %{value: nil}) do
    with {:ok, _} <- Session.put_document(handle.session, handle.namespace, 0, expected),
         do: {:ok, handle}
  end

  defp open_document(handle, expected, %{value: expected}), do: {:ok, handle}
  defp open_document(_handle, _expected, _document), do: {:error, :run_identity_changed}

  @doc "Executes one step once, or revalidates its saved output; never automatically retries."
  @spec step(
          handle :: t(),
          key :: String.t(),
          inputs :: map(),
          fun :: (-> term()),
          opts :: keyword()
        ) :: term()
  def step(handle, key, inputs, fun, opts \\ []) when is_function(fun, 0) do
    with :ok <- valid_inputs(key, inputs),
         {:ok, document} <- status(handle, key) do
      signature =
        Contract.digest(%{
          "identity" => handle.identity,
          "key" => key,
          "inputs" => inputs,
          "approval_required" => Keyword.get(opts, :approval, false)
        })

      advance(handle, key, inputs, signature, document, fun, opts)
    end
  end

  @doc "Returns a step's revision, state, bound inputs, output and attempt history."
  @spec status(handle :: t(), key :: String.t()) :: {:ok, map()} | {:error, term()}
  def status(handle, key), do: Session.document(handle.session, namespace(handle, key))

  @doc "Host approval for the exact pending step revision."
  @spec approve(
          handle :: t(),
          key :: String.t(),
          revision :: non_neg_integer(),
          reason :: String.t()
        ) :: term()
  def approve(handle, key, revision, reason),
    do: transition(handle, key, revision, ["awaiting_approval"], "ready", reason)

  @doc "Host-authorized retry after reconciling effects and stopping the previous worker."
  @spec retry(
          handle :: t(),
          key :: String.t(),
          revision :: non_neg_integer(),
          reason :: String.t()
        ) :: term()
  def retry(handle, key, revision, reason),
    do: transition(handle, key, revision, ["in_doubt", "failed"], "ready", reason)

  @doc "Reconciles uncertain execution using host-validated output and receipt references."
  @spec resolve(
          handle :: t(),
          key :: String.t(),
          revision :: non_neg_integer(),
          output :: map(),
          evidence :: [String.t()]
        ) :: term()
  def resolve(handle, key, revision, output, evidence) do
    with true <- is_list(evidence) and evidence != [] and Enum.all?(evidence, &is_binary/1),
         {:ok, %{value: %{"status" => "in_doubt"} = value}} <- status(handle, key),
         :ok <- Document.validate("flow.output", output) do
      next =
        value
        |> Map.put("status", "completed")
        |> Map.put("output", output)
        |> Map.put("resolution_evidence", evidence)

      Session.put_document(handle.session, namespace(handle, key), revision, next)
    else
      _invalid -> {:error, :invalid_resolution}
    end
  end

  defp advance(handle, key, inputs, digest, %{value: nil}, fun, opts) do
    state = if Keyword.get(opts, :approval, false), do: "awaiting_approval", else: "ready"

    value = %{
      "version" => 1,
      "run_id" => handle.run_id,
      "key" => key,
      "digest" => digest,
      "inputs" => inputs,
      "status" => state,
      "attempts" => [],
      "output" => nil
    }

    with {:ok, document} <- Session.put_document(handle.session, namespace(handle, key), 0, value),
         do: advance(handle, key, inputs, digest, document, fun, opts)
  end

  defp advance(_handle, _key, _inputs, digest, %{value: %{"digest" => stored}}, _fun, _opts)
       when digest != stored,
       do: {:error, :step_identity_changed}

  defp advance(
         _handle,
         key,
         _inputs,
         _digest,
         %{value: %{"status" => "awaiting_approval"}} = document,
         _fun,
         _opts
       ),
       do:
         {:suspended, %{key: key, revision: document.revision, digest: document.value["digest"]}}

  defp advance(
         _handle,
         _key,
         _inputs,
         _digest,
         %{value: %{"status" => "completed", "output" => output}},
         _fun,
         opts
       ) do
    case Keyword.get(opts, :validate) do
      validate when is_function(validate, 1) ->
        validate_cached(validate, output)

      _missing ->
        {:error, :cached_output_requires_validation}
    end
  end

  defp advance(
         handle,
         key,
         _inputs,
         _digest,
         %{value: %{"status" => "ready"} = value} = document,
         fun,
         _opts
       ) do
    if length(value["attempts"]) >= 8 do
      {:error, :attempt_limit}
    else
      with {:ok, intent} <-
             Session.put_document(
               handle.session,
               namespace(handle, key),
               document.revision,
               Map.put(value, "status", "in_doubt")
             ),
           do: execute(handle, key, intent, safe(fun))
    end
  end

  defp advance(_handle, key, _inputs, _digest, _document, _fun, _opts),
    do: {:error, {:requires_recovery, key}}

  defp validate_cached(validate, output) do
    case safe(fn -> validate.(output) end) do
      :ok -> {:ok, output}
      _other -> {:error, :cached_output_invalid}
    end
  end

  defp execute(handle, key, intent, {:ok, output}) when is_map(output) do
    with :ok <- Document.validate("flow.output", output),
         {:ok, _} <-
           Session.put_document(
             handle.session,
             namespace(handle, key),
             intent.revision,
             intent.value |> Map.put("status", "completed") |> Map.put("output", output)
           ),
         do: {:ok, output}
  end

  defp execute(handle, key, intent, {:error, reason, observation})
       when is_map(observation),
       do: failed(handle, key, intent, reason_text(reason), observation)

  defp execute(handle, key, intent, {:error, reason}),
    do: failed(handle, key, intent, reason_text(reason), nil)

  defp execute(_handle, key, _intent, _uncertain), do: {:error, {:requires_recovery, key}}

  defp failed(handle, key, intent, reason, observation) do
    value =
      intent.value
      |> Map.put("status", "failed")
      |> Map.put("reason", String.slice(reason, 0, 1000))
      |> Map.put("output", observation)

    with {:ok, _} <-
           Session.put_document(handle.session, namespace(handle, key), intent.revision, value),
         do: {:error, {:step_failed, key, reason}}
  end

  defp transition(handle, key, revision, allowed, next_status, reason)
       when is_binary(reason) and byte_size(reason) in 1..1000 do
    with {:ok, %{value: %{"status" => status} = value}} <- status(handle, key),
         true <- status in allowed do
      next = transition_value(value, next_status, reason)
      Session.put_document(handle.session, namespace(handle, key), revision, next)
    else
      _other -> {:error, :invalid_transition}
    end
  end

  defp transition(_handle, _key, _revision, _allowed, _next, _reason),
    do: {:error, :decision_reason_required}

  defp transition_value(value, next_status, reason) do
    next = value |> Map.put("status", next_status) |> Map.put("decision", reason)

    if value["status"] in ["in_doubt", "failed"],
      do:
        next
        |> Map.update!("attempts", &(&1 ++ [Map.take(value, ["status", "output", "reason"])]))
        |> Map.put("output", nil),
      else: next
  end

  defp valid_identity(identity) do
    keys = ~w(workflow_digest configuration_digest policy_digest)

    if Enum.all?(keys, &(is_binary(identity[&1]) and byte_size(identity[&1]) > 0)),
      do: Document.validate("flow.identity", identity),
      else: {:error, :invalid_run_identity}
  end

  defp valid_inputs(
         key,
         %{"workspace_snapshot" => snapshot, "upstream_artifacts" => artifacts} = inputs
       )
       when is_binary(key) and byte_size(key) in 1..128 and is_map(snapshot) and
              map_size(snapshot) > 0 and is_map(artifacts),
       do: Document.validate("flow.inputs", inputs)

  defp valid_inputs(_key, _inputs), do: {:error, :snapshot_and_upstream_artifacts_required}

  defp namespace(handle, key),
    do: "flow.step." <> Contract.digest(%{"run" => handle.run_id, "key" => key})

  defp reason_text(reason) when is_binary(reason), do: String.slice(reason, 0, 1000)
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(_reason), do: "operation_failed"

  defp safe(fun) do
    fun.()
  rescue
    _error -> :in_doubt
  catch
    _kind, _reason -> :in_doubt
  end
end
