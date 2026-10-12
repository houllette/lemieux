defmodule Lemieux.CLI.Jobs do
  @moduledoc """
  The lmx local durable-job host and its clients.

  `jobs serve` is a foreground worker, suitable for nohup or a service manager.
  Submit and attach commands are separate clients. Killing a client leaves the
  worker running; killing the worker leaves interrupted jobs quarantined for
  explicit recovery. Policy, credentials, configuration and sandbox come from
  the worker's current ordinary CLI assembly, including on recovery.
  """
  alias Lemieux.CLI
  alias Lemieux.CLI.Jobs.Server
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Run
  alias Lemieux.CLI.Runtime
  alias Lemieux.Jobs
  alias Lemieux.Jobs.Journal.Files
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @switches [
    jobs_dir: :string,
    model: :string,
    max_total_requests: :integer,
    max_total_cost_usd: :float,
    at: :string,
    timeout_ms: :integer,
    cursor: :string
  ]

  @doc "Runs a worker or client command, returning a CLI exit status."
  @spec main(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def main(["serve" | argv], opts), do: serve(argv, opts)

  def main(argv, opts) do
    {given, args, invalid} = OptionParser.parse(argv, strict: @switches)

    with true <- invalid == [],
         {:ok, directory} <- directory(given, opts),
         {:ok, request} <- command(args, given, opts),
         {:ok, request} <- resolution(directory, request),
         {:ok, result} <- Server.request(socket(directory), request, &print/1) do
      if request["op"] != "attach", do: print(result)
      :ok
    else
      false -> fail("invalid jobs options", 2)
      {:error, reason} -> fail(reason, 1)
    end
  end

  defp command(["submit" | prompt], given, opts) when prompt != [] do
    limits =
      Enum.reduce(
        [{:max_total_requests, "max_requests"}, {:max_total_cost_usd, "max_cost_usd"}],
        %{},
        fn {option, key}, limits ->
          if given[option], do: Map.put(limits, key, given[option]), else: limits
        end
      )

    intent = %{
      "prompt" => Enum.join(prompt, " "),
      "cwd" => Keyword.get_lazy(opts, :cwd, &File.cwd!/0),
      "limits" => limits,
      "model" => given[:model],
      "run_at" => given[:at],
      "timeout_ms" => given[:timeout_ms]
    }

    {:ok, %{"op" => "submit", "intent" => intent}}
  end

  defp command([operation, id], _given, _opts) when operation in ~w(get attach cancel recover),
    do: {:ok, %{"op" => operation, "id" => id}}

  defp command(["effects", id], given, _opts),
    do: {:ok, %{"op" => "effects", "id" => id, "cursor" => given[:cursor]}}

  defp command(["list"], given, _opts), do: {:ok, %{"op" => "list", "cursor" => given[:cursor]}}
  defp command(["stop"], _given, _opts), do: {:ok, %{"op" => "stop"}}

  defp command([operation, id, session, call], _given, _opts) when operation in ~w(approve deny),
    do:
      {:ok,
       %{
         "op" => "resolve",
         "id" => id,
         "session_id" => session,
         "call_id" => call,
         "decision" => if(operation == "approve", do: "allow", else: "deny")
       }}

  defp command(["answer", id, session, call, answer], _given, _opts),
    do:
      {:ok,
       %{
         "op" => "answer",
         "id" => id,
         "session_id" => session,
         "call_id" => call,
         "answer" => answer
       }}

  defp command(["reconcile", id, key, path], _given, _opts) do
    with {:ok, %{size: size}} when size <= 32_768 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, decision} when is_map(decision) <- JSON.decode(bytes) do
      {:ok, %{"op" => "reconcile", "id" => id, "key" => key, "decision" => decision}}
    else
      _invalid -> {:error, "reconciliation needs a JSON object file of at most 32 KiB"}
    end
  end

  defp command(_args, _given, opts),
    do:
      {:error,
       "use #{CLI.program(opts)} help jobs for submit, serve, list, get, attach, effects, approve, deny, answer, cancel, recover, reconcile and stop"}

  defp resolution(directory, %{"op" => operation} = request)
       when operation in ["resolve", "answer"] do
    with {:ok, job} <- Server.request(socket(directory), %{"op" => "get", "id" => request["id"]}),
         do: {:ok, Map.put(request, "epoch", job["epoch"])}
  end

  defp resolution(_directory, request), do: {:ok, request}

  defp serve(argv, opts) do
    {worker, remaining} = worker_options(argv, [], [])

    {given, _args, invalid} =
      OptionParser.parse(worker,
        strict: [jobs_dir: :string, max_active: :integer, max_pending: :integer]
      )

    with true <- invalid == [],
         {:ok, directory} <- directory(given, opts),
         {:ok, options} <- Options.parse(remaining, command: :run),
         true <- options.argv == [],
         {:ok, runtime} <- Runtime.mount(opts),
         store =
           Keyword.get(opts, :store, JSONL.new(Path.join(directory, "sessions"))),
         {:ok, manager} <-
           Jobs.start_link(
             journal: Files.new(Path.join(directory, "journal")),
             store: store,
             supervisor: runtime,
             max_active: given[:max_active] || 2,
             max_pending: given[:max_pending] || 100,
             factory: factory(options, opts, store),
             authorize: fn _action, _job, _authority -> :ok end
           ) do
      try do
        case Server.start_link(path: socket(directory), manager: manager, supervisor: runtime) do
          {:ok, server} -> wait_for_worker(server, manager, opts)
          {:error, reason} -> fail(reason, 1)
        end
      after
        if Process.alive?(manager), do: GenServer.stop(manager)
      end
    else
      false -> fail("serve takes worker options followed by ordinary run options", 2)
      {:error, reason} -> fail(reason, 1)
    end
  end

  defp wait_for_worker(server, manager, opts) do
    monitor = Process.monitor(server)
    notify = Keyword.get(opts, :on_serve, fn _server, _manager -> :ok end)
    notify.(server, manager)

    receive do
      {:DOWN, ^monitor, :process, ^server, :normal} -> :ok
      {:DOWN, ^monitor, :process, ^server, reason} -> fail(reason, 1)
    end
  after
    if Process.alive?(server), do: GenServer.stop(server)
  end

  defp worker_options([], worker, other), do: {Enum.reverse(worker), Enum.reverse(other)}

  defp worker_options([flag, value | rest], worker, other)
       when flag in ~w(--jobs-dir --max-active --max-pending),
       do: worker_options(rest, [value, flag | worker], other)

  defp worker_options([arg | rest], worker, other) do
    if hd(String.split(arg, "=", parts: 2)) in ~w(--jobs-dir --max-active --max-pending),
      do: worker_options(rest, [arg | worker], other),
      else: worker_options(rest, worker, [arg | other])
  end

  defp factory(base, opts, store) do
    fn job ->
      options =
        if job["intent"]["model"],
          do: %{
            base
            | model: job["intent"]["model"],
              host: %{base.host | model_source: :flag},
              given: Keyword.put(base.given, :model, job["intent"]["model"])
          },
          else: base

      options =
        case Store.read(store, job["session_id"]) do
          {:ok, _entries} -> %{options | resume: job["session_id"]}
          {:error, :not_found} -> options
        end

      current =
        Keyword.merge(opts,
          cwd: job["intent"]["cwd"],
          store: store,
          interactive?: true,
          approval_timeout: :infinity
        )

      options = Run.resolve_model(options, current)

      with {:ok, current} <- Runtime.with_routes(options, current),
           {:ok, current} <- Runtime.with_workspace(options, current),
           {:ok, prepared} <- Runtime.prepare(Runtime.project_mcp(options, current), current) do
        {:ok, [{:harness, prepared.harness} | prepared.options]}
      end
    end
  end

  defp directory(given, opts) do
    path =
      given[:jobs_dir] || Keyword.get(opts, :jobs_dir) ||
        Path.join(CLI.crash_state_dir(System.get_env()), "jobs")

    path = Path.expand(path)

    with :ok <- File.mkdir_p(path),
         {:ok, %{type: :directory}} <- File.lstat(path),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    else
      {:ok, _not_a_directory} -> {:error, :invalid_jobs_directory}
      error -> error
    end
  end

  defp socket(directory), do: Path.join(directory, "worker.sock")
  defp print(value), do: value |> Lemieux.Contract.json() |> JSON.encode!() |> IO.puts()

  defp fail(reason, status) do
    IO.puts(:stderr, "jobs: #{if is_binary(reason), do: reason, else: inspect(reason)}")
    {:error, status}
  end
end
