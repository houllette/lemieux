defmodule Lemieux.CLI.Jobs.Server do
  @moduledoc """
  Private local transport for the lmx job host.

  The directory and socket are owner-only. No distributed Erlang node, remote
  listener, executable term decoder or stored credential is involved. Frames
  and client count are bounded. An attach connection is only an observer;
  EOF removes its subscription and never cancels the job.
  """
  use GenServer, restart: :temporary
  alias Lemieux.Contract
  alias Lemieux.Jobs
  alias Lemieux.Supervisor, as: Sup
  @max_frame 65_536
  @max_reply 1_048_576
  @max_clients 16
  @terminal ~w(completed failed limited cancelled)

  @doc "Starts the worker socket after its manager has claimed the journal."
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Sends one local JSON request; attach streams subsequent job events."
  @spec request(path :: Path.t(), request :: map(), observe :: (map() -> any())) ::
          {:ok, term()} | {:error, term()}
  def request(path, request, observe \\ fn _event -> :ok end) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(path)},
             0,
             [:binary, packet: :line, packet_size: @max_reply, active: false],
             5_000
           ) do
      try do
        with :ok <- send_json(socket, request),
             {:ok, reply} <- read_json(socket),
             do: consume(socket, reply, request["op"], observe)
      after
        :gen_tcp.close(socket)
      end
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    manager = Keyword.fetch!(opts, :manager)
    runtime = Keyword.fetch!(opts, :supervisor)
    # The manager already owns the host claim. Only that holder may remove
    # a socket left by an interrupted worker; unlinking a live worker's socket
    # would strand its clients while permitting a second listener.
    File.rm(path)

    with {:ok, listener} <-
           :gen_tcp.listen(0, [
             :binary,
             packet: :line,
             packet_size: @max_frame,
             active: false,
             ifaddr: {:local, String.to_charlist(path)},
             send_timeout: 5_000,
             send_timeout_close: true
           ]),
         :ok <- File.chmod(path, 0o600) do
      server = self()

      {:ok, acceptor} =
        Task.Supervisor.start_child(
          Sup.task_supervisor(runtime),
          fn -> accept(listener, server, runtime, manager) end
        )

      {:ok,
       %{
         path: path,
         listener: listener,
         clients: %{},
         manager: manager,
         manager_monitor: Process.monitor(manager),
         acceptor: acceptor
       }}
    else
      error -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:client, pid}, _from, state) when map_size(state.clients) < @max_clients,
    do: {:reply, :ok, put_in(state.clients[Process.monitor(pid)], pid)}

  def handle_call({:client, _pid}, _from, state), do: {:reply, {:error, :client_limit}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{manager_monitor: ref} = state),
    do: {:stop, {:job_host_down, reason}, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | clients: Map.delete(state.clients, ref)}}

  def handle_info(:stop_worker, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    Enum.each(state.clients, fn {_ref, pid} -> Process.exit(pid, :shutdown) end)
    File.rm(state.path)
  end

  defp accept(listener, server, runtime, manager) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, handler} =
          Task.Supervisor.start_child(Sup.task_supervisor(runtime), fn ->
            receive do
              {:socket, socket} -> serve(socket, server, manager)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, {:socket, socket})
        accept(listener, server, runtime, manager)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp serve(socket, server, manager) do
    with :ok <- GenServer.call(server, {:client, self()}),
         {:ok, request} <- read_json(socket) do
      case request do
        %{"op" => "attach", "id" => id} when is_binary(id) ->
          attach(socket, manager, id)

        %{"op" => "stop"} ->
          send_reply(socket, :ok)
          send(server, :stop_worker)

        request ->
          send_reply(socket, dispatch(manager, request))
      end
    else
      {:error, reason} -> send_reply(socket, {:error, reason})
    end
  after
    :gen_tcp.close(socket)
  end

  defp dispatch(manager, %{"op" => "submit", "intent" => intent}) when is_map(intent),
    do: Jobs.submit(manager, intent, :local)

  defp dispatch(manager, %{"op" => "get", "id" => id}) when is_binary(id),
    do: Jobs.get(manager, id, :local)

  defp dispatch(manager, %{"op" => "list"} = request),
    do: Jobs.list(manager, request["cursor"], :local)

  defp dispatch(manager, %{"op" => "effects", "id" => id} = request) when is_binary(id),
    do: Jobs.effects(manager, id, request["cursor"], :local)

  defp dispatch(manager, %{"op" => "cancel", "id" => id}) when is_binary(id),
    do: Jobs.cancel(manager, id, :local)

  defp dispatch(manager, %{"op" => "recover", "id" => id}) when is_binary(id),
    do: Jobs.recover(manager, id, :local)

  defp dispatch(
         manager,
         %{
           "op" => "resolve",
           "id" => id,
           "epoch" => epoch,
           "session_id" => session,
           "call_id" => call,
           "decision" => decision
         } = request
       )
       when is_binary(id) and is_binary(epoch) and is_binary(session) and is_binary(call) and
              decision in ["allow", "deny"] do
    decision =
      if decision == "allow",
        do: :allow,
        else: {:deny, request["reason"] || "denied by current host"}

    Jobs.resolve(manager, id, epoch, session, call, decision, :local)
  end

  defp dispatch(manager, %{"op" => "reconcile", "id" => id, "key" => key, "decision" => decision})
       when is_binary(id) and is_binary(key) and is_map(decision),
       do: Jobs.reconcile(manager, id, key, decision, :local)

  defp dispatch(manager, %{
         "op" => "answer",
         "id" => id,
         "epoch" => epoch,
         "session_id" => session,
         "call_id" => call,
         "answer" => answer
       })
       when is_binary(id) and is_binary(epoch) and is_binary(session) and
              is_binary(call) and (is_binary(answer) or is_map(answer)),
       do: Jobs.answer(manager, id, epoch, session, call, answer, :local)

  defp dispatch(_manager, _request), do: {:error, :invalid_job_command}

  defp attach(socket, manager, id) do
    case Jobs.attach(manager, id, self(), :local) do
      {:ok, job} ->
        :ok = send_reply(socket, {:ok, job})

        if job["status"] not in @terminal do
          :ok = :inet.setopts(socket, active: :once)
          observe(socket, id)
        end

        Jobs.detach(manager, id, self())

      error ->
        send_reply(socket, error)
    end
  end

  defp observe(socket, id) do
    receive do
      {:lemieux_job, ^id, event} ->
        case send_json(socket, %{"event" => Contract.json(event), "job_id" => id}) do
          :ok -> if not terminal?(event), do: observe(socket, id)
          {:error, _closed} -> :ok
        end

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok

      {:tcp, ^socket, _unexpected_input} ->
        :ok
    end
  end

  defp terminal?({:status, %{"status" => status}}),
    do: status in @terminal or status in ["interrupted", "blocked"]

  defp terminal?({:detached, _reason}), do: true
  defp terminal?(_event), do: false

  defp consume(socket, %{"ok" => true, "result" => result}, "attach", observe) do
    observe.(%{"snapshot" => result})

    if result["status"] in @terminal,
      do: {:ok, result},
      else: read_events(socket, result, observe)
  end

  defp consume(_socket, %{"ok" => true, "result" => result}, _operation, _observe),
    do: {:ok, result}

  defp consume(_socket, %{"ok" => false, "error" => reason}, _operation, _observe),
    do: {:error, reason}

  defp consume(_socket, _reply, _operation, _observe), do: {:error, :invalid_worker_reply}

  defp read_events(socket, result, observe) do
    case read_json(socket, :infinity) do
      {:ok, event} ->
        observe.(event)
        read_events(socket, result, observe)

      {:error, :closed} ->
        {:ok, result}

      error ->
        error
    end
  end

  defp read_json(socket, timeout \\ 5_000) do
    with {:ok, bytes} <- :gen_tcp.recv(socket, 0, timeout),
         {:ok, map} when is_map(map) <- JSON.decode(bytes) do
      {:ok, map}
    else
      {:ok, _nonobject} -> {:error, :invalid_json_command}
      error -> error
    end
  end

  defp send_reply(socket, :ok), do: send_reply(socket, {:ok, "ok"})

  defp send_reply(socket, {:ok, result}),
    do: send_json(socket, %{"ok" => true, "result" => Contract.json(result)})

  defp send_reply(socket, {:error, reason}),
    do: send_json(socket, %{"ok" => false, "error" => Contract.json(reason)})

  defp send_json(socket, map) do
    bytes = JSON.encode!(map)

    if byte_size(bytes) < @max_reply,
      do: :gen_tcp.send(socket, [bytes, "\n"]),
      else:
        :gen_tcp.send(socket, [
          JSON.encode!(%{
            "ok" => false,
            "error" => "reply_too_large",
            "event" => "frame_omitted",
            "reason" => "read the durable transcript or journal page"
          }),
          "\n"
        ])
  end
end
