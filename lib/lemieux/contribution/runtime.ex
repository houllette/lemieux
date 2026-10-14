defmodule Lemieux.Contribution.Runtime do
  @moduledoc false
  use GenServer
  alias Lemieux.Contribution
  @timeout 1_000
  @max_jobs 16

  @spec start(owner :: pid(), sources :: [Contribution.t()], context :: map()) ::
          {:ok, pid() | nil}
  def start(_owner, [], _context), do: {:ok, nil}

  def start(owner, sources, context),
    do: GenServer.start(__MODULE__, {owner, Contribution.registry!(sources), context})

  @spec close(runtime :: pid() | nil) :: :ok
  def close(nil), do: :ok

  def close(runtime) do
    GenServer.stop(runtime, :normal, 2_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec status(runtime :: pid() | nil, context :: map()) :: [map()]
  def status(nil, _context), do: []

  def status(runtime, context) do
    names = call(runtime, :names)

    if is_list(names) do
      names
      |> Task.async_stream(fn name -> {name, call(runtime, {:run, name, :status, context})} end,
        max_concurrency: 4,
        timeout: 4_000
      )
      |> Enum.map(fn {:ok, {name, result}} -> status_result(name, result) end)
    else
      []
    end
  end

  @spec command(
          runtime :: pid() | nil,
          namespace :: String.t(),
          name :: String.t(),
          args :: String.t(),
          context :: map()
        ) :: {:ok, map()} | {:error, atom()}
  def command(nil, _namespace, _name, _args, _context), do: {:error, :unavailable}

  def command(runtime, namespace, name, args, context)
      when is_binary(args) and byte_size(args) <= 1_024,
      do: call(runtime, {:run, namespace, {:command, name, args}, context})

  def command(_runtime, _namespace, _name, _args, _context), do: {:error, :invalid_arguments}

  defp call(runtime, operation) do
    GenServer.call(runtime, operation, 3_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp status_result(_name, {:ok, status}), do: status
  defp status_result(name, {:error, :timeout}), do: error(name, "status callback timed out")

  defp status_result(name, {:error, :invalid_status}),
    do: error(name, "invalid status contribution")

  defp status_result(name, {:error, :unavailable}), do: unavailable(name)
  defp status_result(name, _failure), do: error(name, "status callback failed")

  defp error(name, message),
    do: %{"namespace" => name, "state" => "error", "message" => message, "action" => "observe"}

  defp unavailable(name),
    do: %{"namespace" => name, "state" => "unavailable", "action" => "observe"}

  @impl true
  def init({owner, sources, context}) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)

    entries =
      Map.new(
        sources,
        &{&1.namespace,
         %{
           source: &1,
           state: &1.state,
           observer: nil,
           guardian: nil,
           phase: :unavailable,
           waiting: []
         }}
      )

    {:ok,
     %{
       owner: owner,
       owner_ref: owner_ref,
       entries: entries,
       names: Enum.map(sources, & &1.namespace),
       environment: Map.get(context, :environment),
       jobs: %{}
     }, {:continue, {:open, context}}}
  end

  @impl true
  def handle_continue({:open, context}, state) do
    state =
      if context[:environment],
        do: Enum.reduce(state.names, state, &open(&2, &1, context)),
        else: state

    {:noreply, state}
  end

  @impl true
  def handle_call(:names, _from, state), do: {:reply, state.names, state}

  def handle_call({:run, namespace, operation, context}, from, state) do
    cond do
      Map.get(context, :environment) != state.environment ->
        state = reset(state, context)
        {:reply, {:error, :unavailable}, state}

      not Map.has_key?(state.entries, namespace) ->
        {:reply, {:error, :unavailable}, state}

      map_size(state.jobs) >= @max_jobs ->
        {:reply, {:error, :busy}, state}

      state.entries[namespace].phase == :opening ->
        entry = state.entries[namespace]

        if length(entry.waiting) < @max_jobs do
          {:noreply,
           put_in(state.entries[namespace].waiting, [{from, operation, context} | entry.waiting])}
        else
          {:reply, {:error, :busy}, state}
        end

      state.entries[namespace].phase != :ready ->
        {:reply, {:error, :unavailable}, state}

      true ->
        run(state, namespace, operation, context, from)
    end
  end

  defp open(state, namespace, context) do
    entry = state.entries[namespace]
    module = entry.source.module

    if function_exported?(module, :open, 2) do
      # An epoch guardian dies on reset even if open/2 has not yet returned.
      # Late startup code cannot link an observer to the retired epoch.
      guardian =
        spawn_link(fn ->
          receive do
            :close -> :ok
          end
        end)

      context = Map.put(context, :lifecycle_owner, guardian)
      state = put_in(state.entries[namespace].guardian, guardian)
      state = put_in(state.entries[namespace].phase, :opening)
      job(state, namespace, :open, nil, fn -> module.open(entry.source.state, context) end)
    else
      put_in(state.entries[namespace].phase, :ready)
    end
  end

  defp run(state, namespace, :status, context, from) do
    entry = state.entries[namespace]

    {:noreply,
     job(state, namespace, :observe, from, fn ->
       entry.source.module.status(entry.state, context)
     end)}
  end

  defp run(state, namespace, {:command, name, args}, context, from) do
    entry = state.entries[namespace]
    module = entry.source.module

    case entry.source.commands[name] do
      kind when kind in [:observe, :cancel] ->
        if function_exported?(module, :command, 4),
          do:
            {:noreply,
             job(state, namespace, kind, from, fn ->
               module.command(entry.state, name, args, context)
             end)},
          else: {:reply, {:error, :unavailable}, state}

      _unknown ->
        {:reply, {:error, :unknown_command}, state}
    end
  end

  defp job(state, namespace, kind, from, work) do
    manager = self()
    token = make_ref()

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              work.()
            rescue
              _error -> {:error, :callback_failed}
            catch
              _kind, _reason -> {:error, :callback_failed}
            end

          send(manager, {:result, token, result})
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:timeout, token}, @timeout)
    entry = %{namespace: namespace, kind: kind, from: from, pid: pid, ref: ref, timer: timer}
    %{state | jobs: Map.put(state.jobs, token, entry)}
  end

  @impl true
  def handle_info({:result, token, result}, state) do
    case Map.pop(state.jobs, token) do
      {nil, _jobs} ->
        {:noreply, state}

      {job, jobs} ->
        Process.cancel_timer(job.timer)
        Process.demonitor(job.ref, [:flush])
        state = %{state | jobs: jobs}
        {:noreply, complete(state, job, result)}
    end
  end

  def handle_info({:timeout, token}, state) do
    case Map.pop(state.jobs, token) do
      {nil, _jobs} ->
        {:noreply, state}

      {job, jobs} ->
        Process.exit(job.pid, :kill)
        Process.demonitor(job.ref, [:flush])
        {:noreply, complete(%{state | jobs: jobs}, job, {:error, :timeout})}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, owner, _reason},
        %{owner_ref: ref, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.jobs, fn {_token, job} -> job.ref == ref end) do
      nil ->
        {:noreply, state}

      {token, job} ->
        Process.cancel_timer(job.timer)
        state = %{state | jobs: Map.delete(state.jobs, token)}
        {:noreply, complete(state, job, {:error, :callback_failed})}
    end
  end

  def handle_info({:EXIT, observer, _reason}, state) do
    entries =
      Map.new(state.entries, fn {name, entry} ->
        {name,
         if(entry.observer == observer,
           do: %{entry | phase: :unavailable, observer: nil},
           else: entry
         )}
      end)

    {:noreply, %{state | entries: entries}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp complete(state, %{kind: :open, namespace: namespace}, {:ok, runtime_state, observer})
       when is_pid(observer) do
    Process.link(observer)
    entry = state.entries[namespace]

    state =
      put_in(state.entries[namespace], %{
        entry
        | phase: :ready,
          state: runtime_state,
          observer: observer,
          waiting: []
      })

    Enum.reduce(Enum.reverse(entry.waiting), state, fn {from, operation, context}, acc ->
      case run(acc, namespace, operation, context, from) do
        {:noreply, updated} ->
          updated

        {:reply, reply, updated} ->
          GenServer.reply(from, reply)
          updated
      end
    end)
  end

  defp complete(state, %{kind: :open, namespace: namespace}, _failure) do
    if state.entries[namespace].guardian,
      do: Process.exit(state.entries[namespace].guardian, :kill)

    Enum.each(state.entries[namespace].waiting, fn {from, _op, _ctx} ->
      GenServer.reply(from, {:error, :unavailable})
    end)

    put_in(state.entries[namespace], %{
      state.entries[namespace]
      | phase: :unavailable,
        waiting: []
    })
  end

  defp complete(state, job, {:error, reason})
       when reason in [:timeout, :unavailable, :callback_failed, :invalid_status] do
    GenServer.reply(job.from, {:error, reason})
    state
  end

  defp complete(state, job, {:error, _unsafe_reason}),
    do: complete(state, job, {:error, :callback_failed})

  defp complete(state, job, result) do
    GenServer.reply(job.from, Contribution.normalize(result, job.namespace, job.kind))
    state
  end

  defp reset(state, context) do
    cleanup(state)

    entries =
      Map.new(state.entries, fn {name, entry} ->
        {name,
         %{entry | state: entry.source.state, observer: nil, phase: :unavailable, waiting: []}}
      end)

    state = %{state | environment: context[:environment], entries: entries, jobs: %{}}

    if context[:environment],
      do: Enum.reduce(state.names, state, &open(&2, &1, context)),
      else: state
  end

  @impl true
  def terminate(_reason, state), do: cleanup(state)

  defp cleanup(state) do
    Enum.each(state.jobs, fn {_token, job} ->
      Process.cancel_timer(job.timer)
      Process.demonitor(job.ref, [:flush])
      Process.exit(job.pid, :kill)
      if job.from, do: GenServer.reply(job.from, {:error, :unavailable})
    end)

    Enum.each(state.entries, fn {_name, entry} ->
      if entry.guardian, do: Process.exit(entry.guardian, :kill)
      if entry.observer, do: Process.exit(entry.observer, :kill)

      Enum.each(entry.waiting, fn {from, _op, _ctx} ->
        GenServer.reply(from, {:error, :unavailable})
      end)
    end)

    # Callbacks link startup observers before returning a PID. Include those
    # links so closure during startup cannot leave an unregistered observer.
    {:links, links} = Process.info(self(), :links)
    for pid <- links, is_pid(pid), do: Process.exit(pid, :kill)
    :ok
  end
end
