defmodule Lemieux.CLI.CodexModels.Watcher do
  @moduledoc """
  Screen-scoped, bounded Codex catalog refreshes outside the UI/session loop.

  A 30-second credential check detects account changes without polling the
  catalog on every render or synchronous session read. Successful catalogs
  live for five minutes; failures back off for a minute. Credentials are
  resolved afresh, never stored in the cache, and stale in-flight results are
  discarded when their credential source changes. The screen owns lifetime.
  """
  use GenServer, restart: :temporary
  alias Lemieux.CLI.CodexModels
  alias Lemieux.Clock

  @derive {Inspect, only: []}
  defstruct [
    :app,
    :options,
    :opts,
    :tasks,
    :task,
    :deadline,
    :scope,
    :published,
    :clock,
    :poll_timer,
    models: [],
    due: nil
  ]

  @doc "Starts catalog discovery for the CLI's direct connection, owned by the screen."
  @spec start(app :: pid(), options :: Lemieux.CLI.Options.t(), opts :: keyword()) ::
          GenServer.on_start() | :ignore
  def start(app, options, opts) do
    routed? = Enum.any?(Keyword.get(opts, :routes, []), &(elem(&1, 0) == "openai_codex"))

    if Keyword.has_key?(opts, :provider) or routed? do
      :ignore
    else
      runtime = Keyword.get(opts, :supervisor, Lemieux.Supervisor)

      DynamicSupervisor.start_child(
        Lemieux.Supervisor.background_supervisor(runtime),
        {__MODULE__, {app, options, opts}}
      )
    end
  end

  @doc false
  @spec start_link(args :: tuple()) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc false
  @spec poll(watcher :: pid()) :: :ok
  def poll(watcher), do: GenServer.call(watcher, :poll)

  @impl true
  def init({app, options, opts}) do
    Process.monitor(app)
    runtime = Keyword.get(opts, :supervisor, Lemieux.Supervisor)
    tasks = Lemieux.Supervisor.task_supervisor(runtime)
    clock = Keyword.get(opts, :clock)

    discovery =
      Keyword.get(opts, :codex_models, [])
      |> Keyword.put_new(:params, Keyword.get(opts, :params, []))

    {:ok,
     %__MODULE__{
       app: app,
       options: options,
       opts: discovery,
       tasks: tasks,
       clock: clock,
       poll_timer: Clock.send_after(clock, self(), :poll, 30_000)
     }, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, refresh(state)}

  @impl true
  def handle_call(:poll, _from, state), do: {:reply, :ok, refresh(state)}

  @impl true
  def handle_info(:poll, state) do
    timer = Clock.send_after(state.clock, self(), :poll, 30_000)
    {:noreply, refresh(%{state | poll_timer: timer})}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Clock.cancel(state.clock, state.deadline)
    state = %{state | task: nil, deadline: nil}

    {:noreply, accept(state, result)}
  end

  def handle_info({:fetch_timeout, ref}, %{task: %Task{ref: ref}} = state) do
    Task.shutdown(state.task, :brutal_kill)
    {:noreply, accept(%{state | task: nil, deadline: nil}, {:error, :unavailable})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    Clock.cancel(state.clock, state.deadline)
    {:noreply, accept(%{state | task: nil, deadline: nil}, {:error, :unavailable})}
  end

  def handle_info({:DOWN, _ref, :process, app, _reason}, %{app: app} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    if state.deadline, do: Clock.cancel(state.clock, state.deadline)
    Clock.cancel(state.clock, state.poll_timer)
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  defp refresh(state) do
    case CodexModels.connection(state.options, state.opts) do
      {:ok, connection} ->
        state =
          if state.scope != connection.scope, do: reset(state, connection.scope), else: state

        maybe_fetch(state, connection)

      :unconfigured ->
        state |> reset(nil) |> publish(nil)

      {:error, reason} ->
        state |> reset(nil) |> publish(CodexModels.message(reason))
    end
  end

  defp maybe_fetch(state, connection) do
    if state.task == nil and (state.due == nil or Clock.now_ms(state.clock) >= state.due) do
      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          CodexModels.fetch(connection, state.opts)
        end)

      %{
        state
        | task: task,
          deadline: Clock.send_after(state.clock, self(), {:fetch_timeout, task.ref}, 6_000)
      }
    else
      state
    end
  end

  defp reset(state, scope) do
    if state.scope != scope do
      if state.task, do: Task.shutdown(state.task, :brutal_kill)
      if state.deadline, do: Clock.cancel(state.clock, state.deadline)
      publish(%{state | scope: scope, models: [], task: nil, deadline: nil, due: nil}, nil)
    else
      state
    end
  end

  defp complete(state, {:ok, models}),
    do: publish(%{state | models: models, due: Clock.now_ms(state.clock) + 300_000}, nil)

  defp complete(state, {:error, reason}) do
    state = if reason == :unauthorized, do: %{state | models: []}, else: state
    text = CodexModels.message(reason)
    text = if state.models == [], do: text, else: text <> " Previously fetched choices are stale."
    publish(%{state | due: Clock.now_ms(state.clock) + 60_000}, text)
  end

  defp publish(state, notice) do
    if state.published != {state.models, notice},
      do: send(state.app, {:model_catalog, "openai_codex", state.models, notice})

    %{state | published: {state.models, notice}}
  end

  # Timeouts and worker failures need the same scope check as successful HTTP
  # responses: otherwise an old account's cached models could be re-published
  # with a stale warning after its token changed during a held request.
  defp accept(state, result) do
    case CodexModels.connection(state.options, state.opts) do
      {:ok, %{scope: scope}} when scope == state.scope -> complete(state, result)
      _changed -> refresh(%{state | due: nil})
    end
  end
end
