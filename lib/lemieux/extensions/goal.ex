defmodule Lemieux.Extensions.Goal do
  @moduledoc """
  Opt-in goals with host evidence checks and a finite continuation allowance.

  Only the host creates an objective, through `create/4`. Model tools may inspect,
  request verification, or report a blocker; they cannot create goals or increase
  budgets. A check result binds the goal revision, policy ID and workspace
  snapshot before and after verification. Missing, malformed, timed-out or
  changing evidence stays unverified. Completion is never inferred from prose.

  The host must supply `:policy_id`, `:checks`, `:snapshot` and `:max_requests`.
  Checks are named one-argument callbacks returning `{:pass, evidence_refs}` or
  `{:fail, reason}`. Snapshot returns `{:ok, nonempty_json_map}` for the host's
  actual execution environment. Keep policy IDs versioned when checks change.
  `:max_continuations` defaults to zero. Session request limits are clamped to
  the supplied bound, and continuations consumed survive resume. Cancellation,
  errors and non-ordinary stops never trigger autonomous work.

  Optional independent review uses an ordinary bounded, read-only subagent whose
  reservation and usage belong to the parent. See `Verification`. A persisted
  verifying intent prevents duplicate checks; after interruption a host must
  explicitly call `recover/2` before another attempt. Rebind executable checks
  and snapshot authority on resume; transcript data never restores authority.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Entry
  alias Lemieux.Extensions.Goal.Tool
  alias Lemieux.Extensions.Goal.Verification
  alias Lemieux.Harness
  alias Lemieux.Session

  @namespace "lemieux.goal"
  defstruct [
    :policy_id,
    :checks,
    :snapshot,
    :max_requests,
    :reviewer,
    max_continuations: 0,
    verify_timeout_ms: 5_000
  ]

  @impl true
  def apply(harness, opts) do
    config = struct!(__MODULE__, opts)
    validate!(config)

    limit =
      if harness.max_requests,
        do: min(harness.max_requests, config.max_requests),
        else: config.max_requests

    %{harness | max_requests: limit}
    |> Harness.update_tools(&(&1 ++ [Tool.new(config, :get), Tool.new(config, :update)]))
    |> Harness.append_hooks(prepare_next_turn: &prepare/2, stop: &stop(config, &1, &2))
  end

  @doc "Host-authorized creation; replace only a terminal goal at its observed revision."
  @spec create(
          session :: Session.session(),
          revision :: non_neg_integer(),
          objective :: String.t(),
          criteria :: [String.t()]
        ) :: {:ok, map()} | {:error, term()}
  def create(session, revision, objective, criteria) do
    with :ok <- valid_brief(objective, criteria),
         {:ok, current} <- read(session),
         true <- is_nil(current.value) or current.value["status"] in ["completed", "blocked"] do
      Session.put_document(session, @namespace, revision, %{
        "version" => 1,
        "objective" => objective,
        "criteria" => criteria,
        "status" => "active",
        "continuations" => 0,
        "assessment" => nil
      })
    else
      false -> {:error, :unfinished_goal}
      error -> error
    end
  end

  @doc "Reads the current objective and assessment, without model work."
  @spec read(session :: Session.session()) :: {:ok, map()} | {:error, term()}
  def read(session) do
    case Session.document(session, @namespace) do
      {:ok, %{value: nil}} = empty ->
        empty

      {:ok,
       %{
         value: %{
           "version" => 1,
           "objective" => objective,
           "criteria" => criteria,
           "status" => status,
           "continuations" => count
         }
       }} = document
      when status in ["active", "verifying", "unverified", "completed", "blocked"] and
             is_integer(count) and count >= 0 ->
        if valid_brief(objective, criteria) == :ok, do: document, else: {:error, :invalid_goal}

      _invalid ->
        {:error, :invalid_goal}
    end
  end

  @doc "Explicit host recovery of an interrupted verification; does not claim it passed."
  @spec recover(session :: Session.session(), revision :: non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def recover(session, revision) do
    case read(session) do
      {:ok, %{value: %{"status" => "verifying"} = goal}} ->
        Session.put_document(session, @namespace, revision, Map.put(goal, "status", "active"))

      _other ->
        {:error, :not_interrupted}
    end
  end

  @doc false
  @spec verify(
          config :: struct(),
          session :: Session.session(),
          revision :: non_neg_integer(),
          context :: map()
        ) :: {:ok, map()} | {:error, term()}
  def verify(config, session, revision, context) do
    with {:ok, %{value: %{"status" => status} = goal}} when status in ["active", "unverified"] <-
           read(session),
         {:ok, intent} <-
           Session.put_document(
             session,
             @namespace,
             revision,
             Map.put(goal, "status", "verifying")
           ) do
      assessment =
        Verification.run(config, goal, context)
        |> Map.put("goal_revision", revision)
        |> Map.put("policy_id", config.policy_id)

      status = if assessment["status"] == "passed", do: "completed", else: "unverified"
      value = goal |> Map.put("status", status) |> Map.put("assessment", assessment)
      Session.put_document(session, @namespace, intent.revision, value)
    else
      {:ok, _document} -> {:error, :goal_not_verifiable}
      error -> error
    end
  end

  @doc false
  @spec block(session :: Session.session(), revision :: non_neg_integer(), reason :: String.t()) ::
          {:ok, map()} | {:error, term()}
  def block(session, revision, reason) when is_binary(reason) and byte_size(reason) in 1..2000 do
    case read(session) do
      {:ok, %{value: %{"status" => status} = goal}} when status in ["active", "unverified"] ->
        Session.put_document(
          session,
          @namespace,
          revision,
          goal |> Map.put("status", "blocked") |> Map.put("blocker", reason)
        )

      _other ->
        {:error, :goal_not_blockable}
    end
  end

  def block(_session, _revision, _reason), do: {:error, :invalid_blocker}

  @doc false
  @spec prepare(request :: Lemieux.Request.t(), context :: map()) :: term()
  def prepare(request, context) do
    case read(context.session) do
      {:ok, %{value: nil}} ->
        {:ok, request}

      {:ok, document} ->
        entry =
          Entry.new(:user, %{
            "text" => "Host-authorized goal (completion requires checks):\n" <> summary(document)
          })

        {:ok, %{request | entries: request.entries ++ [entry]}}

      {:error, _reason} ->
        {:deny, "goal state unavailable"}
    end
  end

  @doc false
  @spec stop(config :: struct(), reason :: term(), context :: map()) :: term()
  def stop(config, :stop, context) do
    case read(context.session) do
      {:ok, %{value: %{"status" => status}} = document} when status == "active" ->
        case verify(config, context.session, document.revision, context) do
          {:ok, %{value: %{"status" => "unverified"}} = checked} ->
            continue(config, checked, context)

          _other ->
            :allow
        end

      {:ok, %{value: %{"status" => "unverified"}} = document} ->
        continue(config, document, context)

      _other ->
        :allow
    end
  end

  def stop(_config, _reason, _context), do: :allow

  @doc "Compact goal status, including the observed revision."
  @spec summary(document :: map()) :: String.t()
  def summary(%{revision: revision, value: value}),
    do: JSON.encode!(%{"revision" => revision, "goal" => value})

  defp continue(config, document, context) do
    used = document.value["continuations"]

    if used < config.max_continuations do
      case Session.put_document(
             context.session,
             @namespace,
             document.revision,
             document.value |> Map.put("continuations", used + 1) |> Map.put("status", "active")
           ) do
        {:ok, next} ->
          {:deny,
           "Goal remains unverified. Address the recorded checks within the remaining session allowance.\n" <>
             summary(next)}

        _other ->
          :allow
      end
    else
      :allow
    end
  end

  defp valid_brief(objective, criteria) do
    if is_binary(objective) and byte_size(objective) in 1..4000 and is_list(criteria) and
         length(criteria) in 1..16 and
         Enum.all?(criteria, &(is_binary(&1) and byte_size(&1) in 1..200)) and
         length(Enum.uniq(criteria)) == length(criteria),
       do: :ok,
       else: {:error, :invalid_goal_brief}
  end

  defp validate!(config) do
    unless valid_checks?(config) and valid_limits?(config),
      do:
        raise(
          ArgumentError,
          "goal requires versioned checks, snapshot authority and finite request/verification limits"
        )

    Verification.validate_reviewer!(config.reviewer)
  end

  defp valid_checks?(config) do
    is_binary(config.policy_id) and byte_size(config.policy_id) in 1..200 and
      is_map(config.checks) and
      Enum.all?(config.checks, fn {key, fun} -> is_binary(key) and is_function(fun, 1) end) and
      is_function(config.snapshot, 1)
  end

  defp valid_limits?(config) do
    is_integer(config.max_requests) and config.max_requests > 0 and
      is_integer(config.max_continuations) and config.max_continuations in 0..100 and
      is_integer(config.verify_timeout_ms) and config.verify_timeout_ms in 1..60_000
  end
end
