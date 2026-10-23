defmodule Lemieux.CLI.Learning.StudyAllowance do
  @moduledoc """
  A host-authorized subscription allowance shared across staged study invocations.

  Current limits must be supplied again and match the original registration.
  One exclusive owner checkpoints the controller and its outer request ledger
  together before dispatch. Reopening restores consumed requests, token usage
  and the original wall-clock deadline. Unknown or interrupted work closes
  admission; it is never replayed or reset by starting another stage.

  The directory contains accounting only, never credentials or provider state.
  A stale lock or partial checkpoint requires inspection. This helper grants no
  live authorization: the command must obtain that before opening it. The
  controller's finite record bound may stop a study before its request cap.
  """
  alias Lemieux.CLI.Learning.Installation
  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.Contract
  alias Lemieux.JobBudget
  alias Lemieux.Learning.Controller
  alias Lemieux.Learning.Controller.Checkpoint
  alias Lemieux.Request

  @type t :: %{controller: pid(), budget: pid(), lock: Path.t(), timeout_ms: pos_integer()}
  @maximum 2_097_152

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
    with {:ok, recorded} <- recorded(directory, limits),
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
        max_records: 4096,
        cost_mode: :quota,
        learning: Keyword.put(limits, :max_cost_usd, nil),
        recorded: recorded,
        persist: &write(directory, "controller.json", &1)
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

  defp recorded(directory, limits) do
    registration = Path.join(directory, "authorization.json")
    checkpoint = Path.join(directory, "controller.json")
    current = Contract.json(Map.new(limits))

    case {File.exists?(registration), File.exists?(checkpoint)} do
      {false, false} ->
        with :ok <- write(directory, "authorization.json", %{"limits" => current}),
             do: {:ok, nil}

      {true, true} ->
        with {:ok, %{"limits" => ^current}} <- read(registration),
             {:ok, %{"job_budget" => budget} = recorded} when is_map(budget) <- read(checkpoint),
             :ok <- Checkpoint.verify(recorded, Contract.sha256(directory), 4096) do
          {:ok, recorded}
        else
          _invalid -> {:error, :study_allowance_changed_or_invalid}
        end

      _partial ->
        {:error, :incomplete_study_allowance}
    end
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

  defp write(directory, name, value) do
    path = Path.join(directory, name)
    value = Journal.seal(value)

    with true <- byte_size(Contract.encode!(value)) <= @maximum,
         :ok <- Journal.safe(path),
         :ok <- Installation.write(path, value),
         do: File.chmod(path, 0o600)
  end

  defp read(path) do
    with :ok <- Journal.safe(path),
         {:ok, %{type: :regular, size: size}} when size <= @maximum <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, value} <- Contract.decode(bytes),
         :ok <- Contract.verify_digest(value, "sha256"),
         do: {:ok, value}
  end
end
