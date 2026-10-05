defmodule Lemieux.Subagent.Admission do
  @moduledoc """
  Runtime-wide admission for bounded child sessions.

  A whole fan-out is validated and reserved atomically. Runtime slots may make
  some children wait, but a caller never discovers after two children started
  that the third exceeded the root budget or duplicated live work. Reserved
  cost is charged immediately and reconciled to measured usage at completion;
  unknown usage consumes the full reservation rather than becoming free.

  Queues are round-robin by root session. This is deliberately a coordinator,
  not a worker pool: children remain ordinary, addressable `Lemieux.Session`
  processes and a slot is only an admission lease around their active run.

  ## Money is integers here

  Every amount in this module is an integer count of micro-dollars, converted
  at the boundary by `Lemieux.Subagent.Money`. Reservations are taken and
  released against a cap hundreds of times in a long tree, and float addition
  does not round-trip: a released reservation is not exactly the reservation
  taken, so the remaining budget drifts away from anything reconcilable
  against an invoice. Reservations round **up** to the micro, because a
  reservation that rounded down would let a tree spend fractionally past its
  cap. Dollars reappear only in `snapshot/1`, for reading.
  """

  use GenServer

  alias Lemieux.Subagent.Money

  @type child_spec :: %{
          required(:id) => String.t(),
          required(:duplicate_key) => term(),
          required(:reserved_cost_usd) => number()
        }

  @doc "Starts the mount-local admission coordinator."
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  # A tree's request ceiling: a positive count, or none declared.
  defguardp is_request_ceiling(requests)
            when is_nil(requests) or (is_integer(requests) and requests > 0)

  @doc "Atomically reserves a validated fan-out and queues it for fair admission."
  @spec reserve(
          server :: GenServer.server(),
          root_id :: String.t(),
          parent :: pid(),
          group_id :: String.t(),
          group :: pid(),
          children :: [child_spec()],
          root_budget_usd :: number(),
          root_budget_requests :: pos_integer() | nil
        ) :: :ok | {:error, term()}
  def reserve(
        server,
        root_id,
        parent,
        group_id,
        group,
        children,
        root_budget_usd,
        requests \\ nil
      )
      when is_binary(root_id) and is_pid(parent) and is_binary(group_id) and is_pid(group) and
             is_list(children) and is_number(root_budget_usd) and root_budget_usd > 0 and
             is_request_ceiling(requests) do
    GenServer.call(
      server,
      {:reserve, root_id, parent, group_id, group, children, root_budget_usd, requests}
    )
  end

  @doc "Releases one child slot and reconciles its reserved cost."
  @spec release(
          server :: GenServer.server(),
          child_id :: String.t(),
          actual_cost_usd :: number() | nil
        ) ::
          :ok
  def release(server, child_id, actual_cost_usd) when is_binary(child_id) do
    GenServer.cast(server, {:release, child_id, actual_cost_usd})
  end

  @doc "Drops every queued or active admission record owned by a group."
  @spec release_group(server :: GenServer.server(), group_id :: String.t()) :: :ok
  def release_group(server, group_id) when is_binary(group_id) do
    GenServer.cast(server, {:release_group, group_id})
  end

  @doc "Returns bounded live counts and root budget accounting."
  @spec snapshot(server :: GenServer.server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       max_active_runtime: positive!(opts, :max_active_runtime, 8),
       max_active_root: positive!(opts, :max_active_root, 3),
       active: %{},
       queued: %{},
       root_queues: %{},
       roots: :queue.new(),
       duplicates: %{},
       groups: %{},
       group_monitors: %{},
       root_accounts: %{},
       root_monitors: %{}
     }}
  end

  @impl GenServer
  def handle_call(
        {:reserve, root_id, parent, group_id, group, children, root_budget, root_requests},
        _from,
        state
      ) do
    with :ok <- validate_children(children),
         :ok <- unique_group(state, group_id),
         :ok <- root_capacity(state, root_id, length(children)),
         :ok <- unique_children(state, children),
         :ok <- budget_capacity(state, root_id, children, root_budget),
         :ok <- request_capacity(state, root_id, children, root_requests) do
      state =
        do_reserve(state, root_id, parent, group_id, group, children, root_budget, root_requests)

      send(self(), :dispatch)
      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    roots =
      Map.new(state.root_accounts, fn {root_id, account} ->
        {root_id,
         %{
           budget_usd: Money.to_usd(account.budget_micros),
           reserved_usd: Money.to_usd(account.reserved_micros),
           spent_usd: Money.to_usd(account.spent_micros),
           budget_micros: account.budget_micros,
           reserved_micros: account.reserved_micros,
           spent_micros: account.spent_micros,
           budget_requests: account.budget_requests,
           reserved_requests: account.reserved_requests,
           spent_requests: account.spent_requests,
           children: MapSet.size(account.children),
           # Every child admitted under this root whose measured cost the
           # provider never reported. Their reservations were charged in full,
           # so `spent_micros` is an upper bound rather than a measurement,
           # and a reader has to be able to tell which.
           unmeasured_children: account.unmeasured
         }}
      end)

    {:reply,
     %{
       active: map_size(state.active),
       queued: map_size(state.queued),
       duplicates: map_size(state.duplicates),
       roots: roots
     }, state}
  end

  @impl GenServer
  def handle_cast({:release, child_id, actual_cost}, state) do
    state = state |> release_child(child_id, actual_cost) |> dispatch()
    {:noreply, state}
  end

  def handle_cast({:release_group, group_id}, state) do
    state = state |> do_release_group(group_id) |> dispatch()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:dispatch, state), do: {:noreply, dispatch(state)}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    cond do
      group_id = state.group_monitors[monitor] ->
        state = %{state | group_monitors: Map.delete(state.group_monitors, monitor)}
        {:noreply, state |> do_release_group(group_id, false) |> dispatch()}

      root_id = state.root_monitors[monitor] ->
        state = %{state | root_monitors: Map.delete(state.root_monitors, monitor)}
        {:noreply, state |> release_root(root_id) |> dispatch()}

      true ->
        {:noreply, state}
    end
  end

  defp do_reserve(state, root_id, parent, group_id, group, children, root_budget, root_requests) do
    budget_micros = Money.to_micros(root_budget)
    {state, root_account} = root_account(state, root_id, parent, budget_micros)
    group_monitor = Process.monitor(group)
    total = children |> Enum.map(&reserved_micros/1) |> Money.sum()
    requests = Enum.sum(Enum.map(children, &reserved_requests/1))
    child_ids = MapSet.new(children, & &1.id)

    root_account = %{
      root_account
      | budget_micros: min(root_account.budget_micros, budget_micros),
        reserved_micros: root_account.reserved_micros + total,
        budget_requests: narrowest(root_account.budget_requests, root_requests),
        reserved_requests: root_account.reserved_requests + requests,
        children: MapSet.union(root_account.children, child_ids)
    }

    group_record = %{pid: group, monitor: group_monitor, children: child_ids, root_id: root_id}

    state =
      state
      |> put_in([:groups, group_id], group_record)
      |> put_in([:group_monitors, group_monitor], group_id)
      |> put_in([:root_accounts, root_id], root_account)

    Enum.reduce(children, state, fn child, state ->
      record =
        child
        |> Map.merge(%{root_id: root_id, group_id: group_id, group: group})
        |> Map.put(:reserved_micros, reserved_micros(child))
        |> Map.put(:reserved_requests, reserved_requests(child))

      state
      |> put_in([:queued, child.id], record)
      |> put_in([:duplicates, child.duplicate_key], child.id)
      |> enqueue_root(root_id, child.id)
    end)
  end

  defp reserved_micros(%{reserved_cost_usd: usd}), do: Money.to_micros(usd)

  defp reserved_requests(%{reserved_requests: n}) when is_integer(n) and n > 0, do: n
  defp reserved_requests(_child), do: 0

  # A ceiling only ever narrows, the way `budget_micros` does: a later group
  # cannot widen what an earlier one declared.
  defp narrowest(nil, declared), do: declared
  defp narrowest(existing, nil), do: existing
  defp narrowest(existing, declared), do: min(existing, declared)

  defp dispatch(state) when map_size(state.active) >= state.max_active_runtime, do: state

  defp dispatch(state) do
    case next_child(state) do
      {nil, state} ->
        state

      {child_id, state} ->
        case Map.pop(state.queued, child_id) do
          {nil, queued} ->
            dispatch(%{state | queued: queued})

          {record, queued} ->
            send(record.group, {:subagent_admitted, child_id})
            state = %{state | queued: queued, active: Map.put(state.active, child_id, record)}
            dispatch(state)
        end
    end
  end

  defp next_child(state) do
    case :queue.out(state.roots) do
      {:empty, _roots} ->
        {nil, state}

      {{:value, root_id}, roots} ->
        queue = Map.fetch!(state.root_queues, root_id)
        {{:value, child_id}, queue} = :queue.out(queue)

        if :queue.is_empty(queue) do
          {child_id, %{state | roots: roots, root_queues: Map.delete(state.root_queues, root_id)}}
        else
          {child_id,
           %{
             state
             | roots: :queue.in(root_id, roots),
               root_queues: Map.put(state.root_queues, root_id, queue)
           }}
        end
    end
  end

  defp enqueue_root(state, root_id, child_id) do
    new_root? = not Map.has_key?(state.root_queues, root_id)
    queue = :queue.in(child_id, Map.get(state.root_queues, root_id, :queue.new()))
    roots = if new_root?, do: :queue.in(root_id, state.roots), else: state.roots
    %{state | root_queues: Map.put(state.root_queues, root_id, queue), roots: roots}
  end

  defp release_child(state, child_id, actual_cost) do
    record = state.active[child_id] || state.queued[child_id]

    if record do
      charged = Money.charge(actual_cost, record.reserved_micros)
      measured? = Money.to_micros(actual_cost) != :unknown
      account = Map.fetch!(state.root_accounts, record.root_id)

      # Requests are charged at their reservation rather than measured, for the
      # same reason an unmeasured cost is: the child's own request count is not
      # reported back here, and an upper bound is the honest ceiling to hold a
      # tree to. `spent_micros` carries the same caveat.
      reserved_requests = Map.get(record, :reserved_requests, 0)

      account = %{
        account
        | reserved_micros: max(account.reserved_micros - record.reserved_micros, 0),
          spent_micros: account.spent_micros + charged,
          reserved_requests: max(account.reserved_requests - reserved_requests, 0),
          spent_requests: account.spent_requests + reserved_requests,
          unmeasured: account.unmeasured + if(measured?, do: 0, else: 1),
          children: MapSet.delete(account.children, child_id)
      }

      state
      |> Map.update!(:active, &Map.delete(&1, child_id))
      |> Map.update!(:queued, &Map.delete(&1, child_id))
      |> Map.update!(:duplicates, &Map.delete(&1, record.duplicate_key))
      |> put_in([:root_accounts, record.root_id], account)
      |> remove_from_root_queue(record.root_id, child_id)
      |> remove_from_group(record.group_id, child_id)
    else
      state
    end
  end

  defp do_release_group(state, group_id, demonitor? \\ true) do
    case Map.pop(state.groups, group_id) do
      {nil, groups} ->
        %{state | groups: groups}

      {group, groups} ->
        if demonitor?, do: Process.demonitor(group.monitor, [:flush])

        state = %{
          state
          | groups: groups,
            group_monitors: Map.delete(state.group_monitors, group.monitor)
        }

        Enum.reduce(group.children, state, &release_child(&2, &1, nil))
    end
  end

  defp release_root(state, root_id) do
    child_ids =
      state.active
      |> Map.merge(state.queued)
      |> Enum.filter(fn {_id, child} -> child.root_id == root_id end)
      |> Enum.map(&elem(&1, 0))

    state = Enum.reduce(child_ids, state, &release_child(&2, &1, nil))
    %{state | root_accounts: Map.delete(state.root_accounts, root_id)}
  end

  defp remove_from_group(state, group_id, child_id) do
    case state.groups[group_id] do
      nil ->
        state

      group ->
        children = MapSet.delete(group.children, child_id)

        if MapSet.size(children) == 0 do
          Process.demonitor(group.monitor, [:flush])

          %{
            state
            | groups: Map.delete(state.groups, group_id),
              group_monitors: Map.delete(state.group_monitors, group.monitor)
          }
        else
          put_in(state.groups[group_id].children, children)
        end
    end
  end

  defp remove_from_root_queue(state, root_id, child_id) do
    case state.root_queues[root_id] do
      nil ->
        state

      queue ->
        queue = queue |> :queue.to_list() |> Enum.reject(&(&1 == child_id)) |> :queue.from_list()

        if :queue.is_empty(queue) do
          roots =
            state.roots |> :queue.to_list() |> Enum.reject(&(&1 == root_id)) |> :queue.from_list()

          %{state | roots: roots, root_queues: Map.delete(state.root_queues, root_id)}
        else
          put_in(state.root_queues[root_id], queue)
        end
    end
  end

  defp root_account(state, root_id, parent, budget_micros) do
    case state.root_accounts[root_id] do
      nil ->
        monitor = Process.monitor(parent)

        account = %{
          parent: parent,
          monitor: monitor,
          budget_micros: budget_micros,
          reserved_micros: 0,
          spent_micros: 0,
          # The same accounting in requests, for a route that cannot price a
          # child. `nil` means no request ceiling was declared, which is the
          # ordinary metered case.
          budget_requests: nil,
          reserved_requests: 0,
          spent_requests: 0,
          unmeasured: 0,
          children: MapSet.new()
        }

        state = put_in(state.root_monitors[monitor], root_id)
        {state, account}

      account ->
        {state, account}
    end
  end

  defp validate_children(children) when children != [] do
    ids = Enum.map(children, & &1.id)
    duplicate_keys = Enum.map(children, & &1.duplicate_key)

    cond do
      length(ids) != length(Enum.uniq(ids)) ->
        {:error, :duplicate_child_id}

      length(duplicate_keys) != length(Enum.uniq(duplicate_keys)) ->
        {:error, :duplicate_work_in_group}

      # Zero is valid: a request-bounded child reserves no dollars because its
      # route does not price them. Negative never is.
      Enum.any?(children, &(not is_number(&1.reserved_cost_usd) or &1.reserved_cost_usd < 0)) ->
        {:error, :invalid_reservation}

      true ->
        :ok
    end
  end

  defp validate_children(_children), do: {:error, :empty_group}

  defp unique_group(state, group_id) do
    if Map.has_key?(state.groups, group_id), do: {:error, :duplicate_group}, else: :ok
  end

  defp root_capacity(state, root_id, incoming) do
    existing =
      case state.root_accounts[root_id] do
        nil -> 0
        account -> MapSet.size(account.children)
      end

    if existing + incoming <= state.max_active_root,
      do: :ok,
      else: {:error, {:root_limit, state.max_active_root}}
  end

  defp unique_children(state, children) do
    case Enum.find(children, &Map.has_key?(state.duplicates, &1.duplicate_key)) do
      nil -> :ok
      child -> {:error, {:duplicate_work, child.duplicate_key}}
    end
  end

  # Compared in micros and reported in both, so a refusal a person reads is in
  # dollars while the arithmetic that produced it is exact.
  #
  # No declared ceiling is no constraint: an unpriced route that named no tree bound
  # is exactly the state this dimension exists to make expressible, and refusing
  # there would be worse than the dollar cap it replaces.
  defp request_capacity(_state, _root_id, _children, nil), do: :ok

  defp request_capacity(state, root_id, children, root_requests) do
    account = state.root_accounts[root_id]
    reserved = if account, do: account.reserved_requests, else: 0
    spent = if account, do: account.spent_requests, else: 0
    ceiling = narrowest(account && account.budget_requests, root_requests)
    incoming = Enum.sum(Enum.map(children, &reserved_requests/1))

    if spent + reserved + incoming <= ceiling,
      do: :ok,
      else:
        {:error,
         {:root_request_budget_exhausted,
          %{spent: spent, reserved: reserved, incoming: incoming, ceiling: ceiling}}}
  end

  defp budget_capacity(state, root_id, children, root_budget) do
    account = state.root_accounts[root_id]
    budget = Money.to_micros(root_budget)
    reserved = if account, do: account.reserved_micros, else: 0
    spent = if account, do: account.spent_micros, else: 0
    ceiling = if account, do: min(account.budget_micros, budget), else: budget
    incoming = children |> Enum.map(&reserved_micros/1) |> Money.sum()

    if spent + reserved + incoming <= ceiling,
      do: :ok,
      else:
        {:error,
         %{
           reason: :tree_budget,
           spent: Money.to_usd(spent),
           reserved: Money.to_usd(reserved),
           requested: Money.to_usd(incoming),
           cap: Money.to_usd(ceiling),
           micros: %{spent: spent, reserved: reserved, requested: incoming, cap: ceiling}
         }}
  end

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, ":#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end
end
