defmodule Lemieux.Background do
  @moduledoc """
  Supervised commands that outlive the call which started them.

  A background command belongs to one session and one mounted
  `Lemieux.Supervisor`. It keeps consuming the environment's demand-driven
  command stream while the agent moves on, and may be inspected with `poll/3`
  or waited on with `await/4`. `Lemieux.Tools.Bash` exposes the same lifecycle
  to a model; hosts can use this module directly without going through a tool.

  Tasks are intentionally runtime state, not transcript state. Their ids and
  observations are recorded when the bash tool returns, but an operating-system
  process cannot be reconstructed by replaying JSON after its runtime has gone
  away. A task monitors its owning session and is stopped with it, so cancelling
  or terminating a session cannot leave an orphan changing the workspace.

  Completed tasks remain queryable for a bounded retention period (one hour by
  default). Output capture is bounded independently of tool output: the head
  and tail are retained and the omitted byte count is explicit.
  """

  alias Lemieux.Background.Task, as: BackgroundTask
  alias Lemieux.Supervisor, as: Sup

  @default_timeout_ms :timer.hours(1)
  @default_retention_ms :timer.hours(1)
  @default_output_bytes 1_000_000

  @typedoc "The observable state of one background command."
  @type snapshot :: %{
          id: String.t(),
          session_id: String.t(),
          command: String.t(),
          status: :running | :exited | :timed_out | :failed | :cancelled,
          exit_status: non_neg_integer() | nil,
          output: String.t(),
          output_bytes: non_neg_integer(),
          error: String.t() | nil,
          started_at: String.t(),
          finished_at: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @doc """
  Starts a background command under a mounted runtime and returns its id.

  Required options are `:session_id`, `:command`, `:cwd` and `:environment`.
  `:supervisor` defaults to `Lemieux.Supervisor`. Supplying the session pid
  as `:owner` ties cleanup to that process. `:env` is passed to the
  environment's `run` as variables to set (or, with `false`, unset) — see
  `Lemieux.Environment`. Hosts which relocate bash execution may supply the
  same `:runner` callback accepted by `Lemieux.Tools.Bash.new/1`. `:clock` is
  the `Lemieux.Clock` the task's own deadlines (`:timeout_ms`, an `await/4`
  wait, and `:retention_ms` after it finishes) are measured on; the real clock
  when omitted. The command's operating-system timeout stays real.

  The command's output is not capped by the environment: this process keeps a
  bounded head and tail (`:max_output_bytes`, one megabyte by default) and
  counts what it dropped, so a long-lived, chatty command — a dev server, a
  watcher — runs until it exits or its deadline rather than being stopped for
  the volume of its log.

  `:environment` is required rather than defaulted to
  `Lemieux.Environment.local/0`, which it used to be. A host that relocates
  execution and forgets to thread the environment into a background start
  would otherwise get the foreground path confined and the background path
  running on the launching machine, and only the second one would be quiet
  about it. Raising is the one way to make that mistake loud.
  """
  @spec start(opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(opts) when is_list(opts) do
    supervisor = Keyword.get(opts, :supervisor, Sup)
    id = Keyword.get_lazy(opts, :id, &Lemieux.ID.generate/0)

    task_opts =
      opts
      |> Keyword.put(:id, id)
      |> Keyword.put(:supervisor, supervisor)
      |> Keyword.put(:environment, environment!(opts))
      |> Keyword.put_new(:timeout_ms, @default_timeout_ms)
      |> Keyword.put_new(:retention_ms, @default_retention_ms)
      |> Keyword.put_new(:max_output_bytes, @default_output_bytes)

    case DynamicSupervisor.start_child(
           Sup.background_supervisor(supervisor),
           {BackgroundTask, task_opts}
         ) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp environment!(opts) do
    case Keyword.fetch(opts, :environment) do
      {:ok, environment} ->
        environment

      :error ->
        raise ArgumentError,
              "Lemieux.Background.start/1 needs :environment. Pass " <>
                "`environment: Lemieux.Environment.local()` for the launching machine, " <>
                "or the session's `{module, state}`"
    end
  end

  @doc "Returns the latest bounded snapshot without waiting."
  @spec poll(atom(), String.t(), String.t()) :: {:ok, snapshot()} | {:error, :not_found}
  def poll(supervisor \\ Sup, session_id, task_id) do
    call(supervisor, session_id, task_id, :poll)
  end

  @doc """
  Waits up to `timeout_ms` for a terminal state.

  A wait deadline does not cancel the command. It returns
  `{:error, {:timeout, snapshot}}`, including the latest output, so a caller can
  do other work and await or poll the same id later.
  """
  @spec await(atom(), String.t(), String.t(), timeout()) ::
          {:ok, snapshot()} | {:error, :not_found | {:timeout, snapshot()}}
  def await(supervisor \\ Sup, session_id, task_id, timeout_ms \\ 30_000)

  def await(supervisor, session_id, task_id, :infinity) do
    call(supervisor, session_id, task_id, {:await, :infinity}, :infinity)
  end

  def await(supervisor, session_id, task_id, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    call(supervisor, session_id, task_id, {:await, timeout_ms}, timeout_ms + 1_000)
  end

  @doc """
  Subscribes a process to the terminal snapshot without polling.

  Sends `{:lemieux_background, %{event_id: id, task: snapshot}}`. Registration
  and completion are serialized by the task: a late subscriber receives the
  already completed snapshot. Repeated registration while running is idempotent.
  Re-subscribing after completion replays the same event id, so hosts can
  deduplicate delivery. Delivery is a mailbox send, not an acknowledgement or
  permission to spend another model turn. Hosts own durable notification and
  continuation policy; a dead subscriber never changes the command's outcome.
  """
  @spec subscribe(
          supervisor :: atom(),
          session_id :: String.t(),
          task_id :: String.t(),
          subscriber :: pid()
        ) :: :ok | {:error, :not_found}
  def subscribe(supervisor, session_id, task_id, subscriber) when is_pid(subscriber),
    do: call(supervisor, session_id, task_id, {:subscribe, subscriber})

  @doc "Removes a subscriber. An already delivered message cannot be recalled."
  @spec unsubscribe(
          supervisor :: atom(),
          session_id :: String.t(),
          task_id :: String.t(),
          subscriber :: pid()
        ) :: :ok | {:error, :not_found}
  def unsubscribe(supervisor, session_id, task_id, subscriber) when is_pid(subscriber),
    do: call(supervisor, session_id, task_id, {:unsubscribe, subscriber})

  @doc "Stops a running command. Completed commands make this an idempotent success."
  @spec cancel(atom(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def cancel(supervisor \\ Sup, session_id, task_id) do
    case call(supervisor, session_id, task_id, :cancel) do
      {:ok, _snapshot} -> :ok
      {:error, :not_found} = error -> error
    end
  end

  defp call(supervisor, session_id, task_id, message, timeout \\ 5_000) do
    case Registry.lookup(Sup.background_registry(supervisor), {session_id, task_id}) do
      [{pid, _value}] -> safe_call(pid, message, timeout)
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  defp safe_call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, _reason -> {:error, :not_found}
  end
end
