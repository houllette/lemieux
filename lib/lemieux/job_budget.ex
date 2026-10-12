defmodule Lemieux.JobBudget do
  @moduledoc """
  One host-owned allowance shared by every participant in a job.

  Requests and paid tools reserve atomically before dispatch. Money is integer
  micro-dollars, rounded up at admission, so concurrent children cannot spend
  the same remainder. Settling charges actual usage and releases the unused
  reservation; request counts are never refunded. Missing prices, interrupted
  calls and lost owners remain unmeasured and close a dollar-limited budget.

  A session opts in with `:job_limits`, or inherits a host's `:job_budget`.
  The former mounts this temporary process under the supplied runtime and
  checkpoints accounting in the root transcript. Resume uses those facts with
  the current host's limits; it never restores executable authority. Hosts
  making auxiliary provider calls use `run/4` against the same ledger.
  Estimates are admission bounds, not provider-enforced billing limits: an
  actual charge above its estimate is recorded and prevents further spending.
  """

  use GenServer, restart: :temporary

  alias Lemieux.Provider
  alias Lemieux.Request
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Document
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Usage

  @namespace "lemieux.job_budget"
  @micros 1_000_000

  @doc "Starts a ledger with current host limits and optional recorded spend."
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The accounting checkpoint namespace."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc false
  @spec mount(runtime :: atom(), entries :: [Lemieux.Entry.t()], limits :: keyword()) :: pid()
  def mount(runtime, entries, limits) do
    {:ok, %{value: value}} = Document.read(Enum.reverse(entries), @namespace)
    recorded = value || %{}
    delegated? = Enum.any?(entries, &(&1.type in [:subagent_spawn, :subagent_result]))
    known = if delegated?, do: nil, else: Accounting.measured_spend(entries)
    requests = if delegated?, do: nil, else: Enum.count(entries, &(&1.type == :request))
    interrupted? = (recorded["active"] || 0) > 0

    spent =
      if interrupted? or recorded["reserved_usd"] not in [nil, 0, 0.0],
        do: nil,
        else: Map.get(recorded, "spent_usd", known)

    opts =
      Keyword.merge(limits,
        owner: self(),
        spent_usd: spent,
        requests: if(interrupted?, do: nil, else: Map.get(recorded, "requests", requests))
      )

    {:ok, pid} =
      DynamicSupervisor.start_child(Sup.background_supervisor(runtime), {__MODULE__, opts})

    pid
  end

  @doc "Checks admission without reserving; dispatch must still call `reserve/3`."
  @spec check(
          server :: GenServer.server() | nil,
          estimate :: number() | nil,
          requests :: non_neg_integer()
        ) :: :ok | {:error, map()}
  def check(nil, _estimate, _requests), do: :ok
  def check(server, estimate, requests), do: GenServer.call(server, {:check, estimate, requests})

  @doc "Atomically reserves estimated dollars and consumes the named request count."
  @spec reserve(
          server :: GenServer.server() | nil,
          estimate :: number() | nil,
          requests :: non_neg_integer()
        ) :: {:ok, reference() | nil} | {:error, map()}
  def reserve(nil, _estimate, _requests), do: {:ok, nil}

  def reserve(server, estimate, requests),
    do: GenServer.call(server, {:reserve, estimate, requests})

  @doc "Settles a reservation once; `nil` actual usage stays unknown."
  @spec settle(
          server :: GenServer.server() | nil,
          lease :: reference() | nil,
          actual_usd :: number() | nil
        ) :: :ok
  def settle(nil, _lease, _actual), do: :ok
  def settle(_server, nil, _actual), do: :ok
  def settle(server, lease, actual), do: GenServer.call(server, {:settle, lease, actual})

  @doc "Reports inclusive measured spend, outstanding reservations, requests and limits."
  @spec snapshot(server :: GenServer.server() | nil) :: map() | nil
  def snapshot(nil), do: nil
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Checkpoints an owned ledger before an auxiliary effect starts."
  @spec checkpoint(server :: GenServer.server() | nil) :: :ok
  def checkpoint(nil), do: :ok

  def checkpoint(server) do
    case GenServer.call(server, :owner) do
      nil -> :ok
      owner -> GenServer.call(owner, :checkpoint_job_budget)
    end
  end

  @doc "Runs an auxiliary provider request within this job's admission and accounting."
  @spec run(
          server :: GenServer.server() | nil,
          provider :: Provider.t(),
          request :: Request.t(),
          emit :: Provider.emit()
        ) :: :ok | {:error, term()}
  def run(server, provider, request, emit) do
    estimate = Provider.estimate_cost(provider, request)

    case reserve(server, estimate, 1) do
      {:ok, lease} ->
        ref = make_ref()
        owner = self()

        try do
          :ok = checkpoint(server)

          Provider.run(provider, request, fn event ->
            if match?({:usage, _}, event), do: send(owner, {ref, event})
            emit.(event)
          end)
        after
          settle(server, lease, reported_cost(ref, request.model, nil))
          checkpoint(server)
        end

      {:error, reason} ->
        {:error, {:job_budget, reason}}
    end
  end

  defp reported_cost(ref, model, cost) do
    receive do
      {^ref, {:usage, usage}} ->
        reported_cost(ref, model, Usage.cost_usd(Usage.normalize(usage, model)))
    after
      0 -> cost
    end
  end

  @impl GenServer
  def init(opts) do
    max_cost = Keyword.get(opts, :max_cost_usd)
    max_requests = Keyword.get(opts, :max_requests)

    unless is_nil(max_cost) or (is_number(max_cost) and max_cost >= 0),
      do: raise(ArgumentError, "job max_cost_usd must be non-negative")

    unless is_nil(max_requests) or (is_integer(max_requests) and max_requests > 0),
      do: raise(ArgumentError, "job max_requests must be positive")

    owner = Keyword.get(opts, :owner)

    {:ok,
     %{
       cap: micros(max_cost),
       max_requests: max_requests,
       spent: micros(Keyword.get(opts, :spent_usd, 0)),
       requests: Keyword.get(opts, :requests, 0),
       reserved: 0,
       leases: %{},
       unmeasured: 0,
       owner_pid: owner,
       owner: if(is_pid(owner), do: Process.monitor(owner))
     }}
  end

  @impl GenServer
  def handle_call(:owner, _from, state), do: {:reply, state.owner_pid, state}

  def handle_call({:check, estimate, requests}, _from, state),
    do: {:reply, capacity(state, estimate, requests), state}

  def handle_call({:reserve, estimate, requests}, {owner, _tag}, state) do
    case capacity(state, estimate, requests) do
      :ok ->
        lease = make_ref()
        amount = micros(estimate) || 0
        reservation = %{amount: amount, owner: owner, monitor: Process.monitor(owner)}

        {:reply, {:ok, lease},
         %{
           state
           | reserved: state.reserved + amount,
             requests: add(state.requests, requests),
             leases: Map.put(state.leases, lease, reservation)
         }}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:settle, lease, actual}, _from, state),
    do: {:reply, :ok, reconcile(state, lease, actual)}

  def handle_call(:snapshot, _from, state) do
    state =
      Enum.reduce(state.leases, state, fn {lease, reservation}, current ->
        if Process.alive?(reservation.owner), do: current, else: reconcile(current, lease, nil)
      end)

    {:reply,
     %{
       spent_usd: dollars(state.spent),
       reserved_usd: dollars(state.reserved),
       requests: state.requests,
       max_requests: state.max_requests,
       max_cost_usd: dollars(state.cap),
       unmeasured: state.unmeasured,
       active: map_size(state.leases)
     }, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    lease =
      Enum.find_value(state.leases, fn {lease, reservation} ->
        if reservation.monitor == ref, do: lease
      end)

    {:noreply, reconcile(state, lease, nil)}
  end

  defp capacity(state, estimate, requests) do
    with :ok <- request_capacity(state, requests), do: cost_capacity(state, estimate, requests)
  end

  defp request_capacity(%{max_requests: nil}, _requests), do: :ok
  defp request_capacity(_state, 0), do: :ok

  defp request_capacity(state, requests) do
    if is_integer(state.requests) and state.requests + requests <= state.max_requests,
      do: :ok,
      else:
        {:error,
         %{kind: :requests, spent: state.requests, estimate: requests, cap: state.max_requests}}
  end

  defp cost_capacity(%{cap: nil}, _estimate, _requests), do: :ok
  defp cost_capacity(_state, 0, 0), do: :ok

  defp cost_capacity(state, estimate, _requests) do
    amount = micros(estimate)

    if is_integer(state.spent) and is_integer(amount) and
         state.spent + state.reserved + amount <= state.cap,
       do: :ok,
       else:
         {:error,
          %{kind: :cost, spent: dollars(state.spent), estimate: estimate, cap: dollars(state.cap)}}
  end

  defp reconcile(state, lease, actual) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {reservation, leases} ->
        Process.demonitor(reservation.monitor, [:flush])
        measured = micros(actual)

        %{
          state
          | leases: leases,
            reserved: state.reserved - reservation.amount,
            spent: add(state.spent, measured),
            unmeasured: state.unmeasured + if(is_nil(measured), do: 1, else: 0)
        }
    end
  end

  defp add(nil, _other), do: nil
  defp add(_value, nil), do: nil
  defp add(value, other), do: value + other
  defp micros(value) when is_number(value) and value >= 0, do: ceil(value * @micros)
  defp micros(_value), do: nil
  defp dollars(nil), do: nil
  defp dollars(value), do: value / @micros
end
