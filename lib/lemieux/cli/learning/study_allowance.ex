defmodule Lemieux.CLI.Learning.StudyAllowance do
  @moduledoc """
  A host-authorized subscription allowance shared across staged study invocations.

  Current limits must be supplied again and match the latest registration.
  One exclusive owner checkpoints the controller and its outer request ledger
  together before dispatch. Reopening restores consumed requests, token usage
  and the original wall-clock deadline. Unknown or interrupted work closes
  admission unless a host explicitly approves a separate conservative reserve
  for that exact quota task request. Actual usage stays unknown; starting
  another stage never replays, resets or treats the call as free.

  The directory contains accounting only, never credentials or provider state.
  A stale lock or partial checkpoint requires inspection. This helper grants no
  live authorization: the command must obtain that before opening it. The
  controller's finite record bound may stop a study before its request cap.
  """
  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.CLI.Learning.StudyRegistration
  alias Lemieux.Contract
  alias Lemieux.JobBudget
  alias Lemieux.Learning.Controller
  alias Lemieux.Request

  @type t :: %{controller: pid(), budget: pid(), lock: Path.t(), timeout_ms: pos_integer()}

  @spec open(directory :: Path.t(), limits :: keyword()) :: {:ok, t()} | {:error, term()}
  def open(directory, limits) do
    directory = Path.expand(directory)
    lock = Path.join(directory, "owner.lock")

    with true <- valid_limits?(limits),
         :ok <- Journal.safe(directory),
         :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.mkdir(lock) do
      case mount(directory, lock, limits) do
        {:ok, _handle} = result ->
          result

        error ->
          File.rmdir(lock)
          error
      end
    else
      _refused -> {:error, :study_allowance_unavailable}
    end
  end

  defp mount(directory, lock, limits) do
    with {:ok, recorded, persist} <- StudyRegistration.load(directory, limits),
         {:ok, budget} <-
           JobBudget.start_link(
             max_requests: limits[:max_requests],
             recorded: if(recorded, do: recorded["job_budget"], else: %{})
           ) do
      options = [
        job_id: Contract.sha256(directory),
        job_budget: budget,
        max_tokens: limits[:max_tokens],
        max_time_ms: limits[:max_time_ms],
        max_records: 8192,
        cost_mode: :quota,
        learning: Keyword.put(limits, :max_cost_usd, nil),
        recorded: recorded,
        persist: persist
      ]

      case Controller.start_link(options) do
        {:ok, controller} ->
          {:ok,
           %{
             controller: controller,
             budget: budget,
             lock: lock,
             timeout_ms: min(180_000, limits[:max_time_ms])
           }}

        error ->
          GenServer.stop(budget)
          error
      end
    end
  end

  @doc """
  Records an explicitly approved increase of accumulated limits.

  The caller supplies both the previous and approved totals plus an audit note.
  No usage, request, stop, or original start is reset. The original checkpoint
  is retained; one atomic versioned registration stores the new limits and
  checkpoint together. An old reader refuses the amended registration.
  Unknown usage still prevents dispatch. The directory must have no owner.
  """
  @spec amend(
          directory :: Path.t(),
          previous :: keyword(),
          limits :: keyword(),
          approval :: String.t()
        ) ::
          {:ok, map()} | {:error, term()}
  def amend(directory, previous, limits, approval) do
    directory = Path.expand(directory)
    lock = Path.join(directory, "owner.lock")

    with true <- valid_limits?(previous) and valid_limits?(limits),
         :ok <- Journal.safe(directory),
         :ok <- File.mkdir(lock) do
      try do
        StudyRegistration.amend(directory, previous, limits, approval)
      after
        File.rmdir(lock)
      end
    else
      _refused -> {:error, :study_amendment_unavailable}
    end
  end

  @doc """
  Charges an explicitly approved budget reserve for one unmeasured task request.

  This never supplies measured usage or qualifies the failed task. Its immutable
  receipt binds the exact unknown record. A version-two controller checkpoint
  keeps actual accounting separate from admission's conservative token total;
  old readers refuse it. Quota mode, finite existing limits, the original
  deadline, all request charges and unknown records remain intact. A subsequent
  unmeasured request has no reserve and closes admission again.
  """
  @spec reserve_unknown(
          directory :: Path.t(),
          limits :: keyword(),
          id :: String.t(),
          tokens :: pos_integer(),
          approval :: String.t()
        ) :: {:ok, map()} | {:error, term()}
  def reserve_unknown(directory, limits, id, tokens, approval) do
    directory = Path.expand(directory)
    lock = Path.join(directory, "owner.lock")

    with true <- valid_limits?(limits),
         :ok <- Journal.safe(directory),
         :ok <- File.mkdir(lock) do
      try do
        StudyRegistration.reserve_unknown(directory, limits, id, tokens, approval)
      after
        File.rmdir(lock)
      end
    else
      _refused -> {:error, :study_reserve_unavailable}
    end
  end

  @doc "Known usage plus separately approved conservative reserves, or nil when admission is uncertain."
  @spec admission_tokens(handle :: t()) :: non_neg_integer() | nil
  def admission_tokens(handle) do
    checkpoint = snapshot(handle)
    Map.get(checkpoint, "budget_tokens", checkpoint["accounting"]["tokens"])
  end

  @spec provider(handle :: t(), role :: atom(), provider :: Lemieux.Provider.t()) ::
          Lemieux.Provider.t()
  def provider(handle, role, provider),
    do:
      Controller.provider(handle.controller, controller_role(role), provider,
        token_bound: &token_bound/1,
        timeout_ms: handle.timeout_ms
      )

  # The physical recorder retains asset-specific roles. The shared controller
  # admits its fixed semantic roles; passing asset_proposer through unchanged
  # refused the first typed-asset call before dispatch and poisoned the child
  # experiment's aggregate usage, despite a complete physical ledger.
  defp controller_role(:asset_proposer), do: :proposer
  defp controller_role(:asset_critic), do: :critic
  defp controller_role(role), do: role

  defp token_bound(%Request{params: params} = request) do
    case Keyword.get(params, :max_tokens) do
      tokens when is_integer(tokens) and tokens > 0 -> Request.estimated_tokens(request)
      _unknown -> nil
    end
  end

  @spec snapshot(handle :: t()) :: map()
  def snapshot(handle), do: Controller.snapshot(handle.controller)

  @spec close(handle :: t()) :: :ok | {:error, term()}
  def close(handle) do
    _snapshot = snapshot(handle)
    :ok = GenServer.stop(handle.controller)
    :ok = GenServer.stop(handle.budget)
    File.rmdir(handle.lock)
  end

  defp valid_limits?(limits) do
    Keyword.keys(limits) |> Enum.sort() == [:max_requests, :max_time_ms, :max_tokens] and
      Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end)
  end
end
