defmodule Lemieux.Hooks.SessionContext do
  @moduledoc false

  # Where a Claude Code `SessionStart` hook's output waits for the session's
  # first prompt.
  #
  # Claude Code adds what a `SessionStart` hook prints to the model's context.
  # Here session-start hooks run in a task of their own while the session is
  # already taking prompts, and a prompt's hooks run in another task; neither
  # is the session process, and neither can wait for the other through it. So
  # one small server per session holds the output between them: whichever
  # task asks first starts it, the session-start task puts what its hooks
  # printed, and the first prompt's hook task takes it, waiting a bounded time
  # if those hooks are still running. It lives as long as the session does,
  # so a later prompt finds it emptied rather than starting a fresh one that
  # would wait for output that is never coming.
  #
  # It is a session's background process, like `Lemieux.Tool.FileState`:
  # started under the runtime's background supervisor and registered in its
  # background registry, keyed by the session's pid. Registered in the
  # sessions registry instead, it was listed by `Lemieux.sessions/1` as a
  # session, and a plain receive loop never answered the `GenServer.stop/3`
  # a host's shutdown sends every session — quitting the terminal UI waited
  # two minutes per session with a SessionStart hook.
  #
  # A context without a session or a runtime — a host calling
  # `Lemieux.Hooks.session_start/3` by hand — has nowhere to keep anything,
  # and gets the hooks run with their output dropped.

  use GenServer, restart: :temporary

  alias Lemieux.Supervisor, as: Sup

  @doc "Leaves what the session-start hooks said for the session's next prompt."
  @spec put(context :: map(), texts :: [String.t()]) :: :ok
  def put(context, texts) when is_list(texts) do
    case holder(context) do
      {:ok, pid} -> GenServer.cast(pid, {:put, texts})
      :error -> :ok
    end
  end

  @doc """
  What the session-start hooks said, once: the first caller gets it and every
  later one gets `[]`. Waits up to `timeout` milliseconds for hooks still
  running; a caller that gives up leaves the output for the next one.
  """
  @spec take(context :: map(), timeout :: non_neg_integer()) :: [String.t()]
  def take(context, timeout) when is_integer(timeout) and timeout >= 0 do
    case holder(context) do
      {:ok, pid} -> await(pid, timeout)
      :error -> []
    end
  end

  @doc false
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    supervisor = Keyword.fetch!(opts, :supervisor)
    session = Keyword.fetch!(opts, :session)
    name = {:via, Registry, {Sup.background_registry(supervisor), {__MODULE__, session}}}
    GenServer.start_link(__MODULE__, session, name: name)
  end

  @impl GenServer
  def init(session) do
    Process.monitor(session)
    {:ok, %{texts: nil, taken?: false, waiting: []}}
  end

  @impl GenServer
  def handle_call({:take, _ref}, _from, %{taken?: true} = state), do: {:reply, [], state}

  def handle_call({:take, ref}, from, %{texts: nil} = state),
    do: {:noreply, %{state | waiting: [{from, ref} | state.waiting]}}

  def handle_call({:take, _ref}, _from, state),
    do: {:reply, state.texts, %{state | texts: nil, taken?: true}}

  @impl GenServer
  def handle_cast({:put, texts}, %{waiting: []} = state),
    do: {:noreply, %{state | texts: (state.texts || []) ++ texts}}

  # The longest waiter is the first prompt; anyone after it was a later one.
  def handle_cast({:put, texts}, %{waiting: waiting} = state) do
    [{first, _ref} | rest] = Enum.reverse(waiting)
    GenServer.reply(first, texts)
    Enum.each(rest, fn {from, _ref} -> GenServer.reply(from, []) end)
    {:noreply, %{state | waiting: [], taken?: true}}
  end

  def handle_cast({:cancel, ref}, state),
    do: {:noreply, %{state | waiting: List.keydelete(state.waiting, ref, 1)}}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _session, _reason}, state),
    do: {:stop, :normal, state}

  # A caller that stops waiting withdraws, so output that arrives later
  # stays for the next prompt instead of going to a reply nobody reads.
  defp await(pid, timeout) do
    ref = make_ref()

    try do
      GenServer.call(pid, {:take, ref}, timeout)
    catch
      :exit, {:timeout, _call} ->
        GenServer.cast(pid, {:cancel, ref})
        []

      :exit, _gone ->
        []
    end
  end

  defp holder(%{session: session, supervisor: supervisor})
       when is_pid(session) and is_atom(supervisor) and not is_nil(supervisor) do
    registry = Sup.background_registry(supervisor)

    if Process.whereis(registry),
      do: lookup_or_start(registry, supervisor, session),
      else: :error
  end

  defp holder(_context), do: :error

  defp lookup_or_start(registry, supervisor, session) do
    case Registry.lookup(registry, {__MODULE__, session}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> start(supervisor, session)
    end
  end

  defp start(supervisor, session) do
    case DynamicSupervisor.start_child(
           Sup.background_supervisor(supervisor),
           {__MODULE__, supervisor: supervisor, session: session}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} -> :error
    end
  end
end
