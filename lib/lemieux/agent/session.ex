defmodule Lemieux.Agent.Session do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Runs one bounded prompt through the ordinary Lemieux session API.

  The caller supplies a provider and model. Credentials and provider routing
  therefore remain runtime configuration and never enter a manifest or report.
  A provider or model left out, or a provider, store or model given as `nil`,
  is `{:error, {key, :required}}`, and a provider or store that is not a
  `{module, state}` pair is `{:error, {key, :invalid}}`: a result, rather
  than the raise `Lemieux.start_session/1` would make in the caller.
  A mounted supervisor and store may also be supplied. The default local
  runtime is lazily mounted on an explicit run and shared until the VM exits;
  it is detached from individual callers so concurrent attempts cannot stop
  each other. Hosts needing restart/lifecycle ownership mount their own tree
  before starting workers and pass `:supervisor`. `:detach_runtime` allows a
  local host adapter to give a lazily created named runtime the same shared
  lifetime; it never changes the ownership of an already mounted tree. Nothing
  starts on library load. This is synchronous: UI callbacks should invoke it
  from their supervised task boundary, not block the UI process.

  Usage totals retain reported counters. `usage["requests"]` counts usage
  reports, while `tool_metrics["requests"]` counts recorded direct requests.
  An unanswered request can therefore leave the reported totals partial. Check
  request coverage and terminal run evidence before treating them as full totals.

  A host deadline cancels the session and returns `{:error, :timeout, observation}`,
  preserving the terminal transcript and workspace changes. The session is
  given the same deadline as `:deadline_ms`, unless `:session_options` names
  another, so `Lemieux.Extensions.Budget` can tell the model how long it has. The deadline is
  measured on the `:clock` option (a `Lemieux.Clock`; the real one when
  omitted), so a test can reach it without waiting. When a direct request
  is unanswered or the host deadline expires, `cost_usd` remains unknown and
  reported dollars are retained as `observed_cost_usd`. Otherwise a cost-capped
  benchmark would charge only the earlier replies instead of reserving for the
  unmeasured work.
  """

  @behaviour Lemieux.Agent

  alias Lemieux.Benchmark.Resources
  alias Lemieux.Benchmark.WorkspaceSnapshot
  alias Lemieux.Clock
  alias Lemieux.Entry
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Supervisor, as: Sup

  @default_supervisor Lemieux.Agent.SessionSupervisor

  @impl Lemieux.Agent
  def run(%{prompt: _prompt, cwd: _cwd, timeout_ms: _timeout} = task, opts) do
    with {:ok, before_snapshot} <- WorkspaceSnapshot.capture(task.cwd),
         {:ok, provider} <- required(opts, :provider),
         {:ok, model} <- required(opts, :model),
         {:ok, supervisor} <-
           mount(
             Keyword.get(opts, :supervisor, @default_supervisor),
             Keyword.get(opts, :detach_runtime, not Keyword.has_key?(opts, :supervisor))
           ),
         {:ok, session} <- start_session(task, opts, provider, model, supervisor),
         {:ok, observation} <- execute(session, task, opts, supervisor),
         {:ok, after_snapshot} <- WorkspaceSnapshot.capture(task.cwd) do
      observation
      |> Map.put("changed_paths", WorkspaceSnapshot.changed(before_snapshot, after_snapshot))
      # Local execution cannot observe writes performed outside the workspace.
      # A host-owned microVM runtime must return a real list for safety cases.
      |> Map.put("safety_violations", nil)
      |> result()
    end
  end

  defp result(%{"finish_reason" => reason} = observation)
       when reason in [":benchmark_timeout", ":agent_timeout"],
       do: {:error, :timeout, observation}

  defp result(observation), do: {:ok, observation}

  defp required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} -> {:error, {key, :required}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, {key, :required}}
    end
  end

  defp mount(supervisor, detach?) when is_atom(supervisor) and is_boolean(detach?) do
    case Process.whereis(supervisor) do
      nil -> mounted(Sup.start_link(name: supervisor), supervisor, detach?)
      _pid -> ready(supervisor)
    end
  end

  defp mounted({:ok, pid}, supervisor, true) do
    # The first benchmark worker used to own the shared runtime. Its normal
    # exit stopped peers and discarded their paid observations. Detach only
    # a newly created convenience runtime; never alter an existing host tree.
    Process.unlink(pid)
    {:ok, supervisor}
  end

  defp mounted({:ok, _pid}, supervisor, false), do: {:ok, supervisor}
  defp mounted({:error, {:already_started, _pid}}, supervisor, _detach?), do: ready(supervisor)
  defp mounted({:error, reason}, _supervisor, _detach?), do: {:error, {:supervisor, reason}}

  # A supervisor's name is registered before `init/1` has started its children, so
  # a worker that finds the name taken may call the session supervisor before it
  # exists — two concurrent benchmark workers did exactly that, and the loser's
  # `:noproc` was counted against the model. A call into the supervisor is queued
  # until `init/1` returns, so asking for its child count is a readiness wait with
  # no polling.
  defp ready(supervisor) do
    _children = Supervisor.count_children(supervisor)
    {:ok, supervisor}
  catch
    :exit, reason -> {:error, {:supervisor, reason}}
  end

  defp start_session(task, opts, provider, model, supervisor) do
    sessions_dir =
      Keyword.get_lazy(opts, :sessions_dir, fn ->
        Path.join(System.tmp_dir!(), "lemieux-benchmark-sessions")
      end)

    base = [
      supervisor: supervisor,
      provider: provider,
      store: Keyword.get(opts, :store, JSONL.new(sessions_dir)),
      model: model,
      subscriber: self(),
      cwd: task.cwd,
      # The lane retries a timed-out attempt itself and counts what it paid
      # for; a session that also retried underneath it would hide the
      # network from the measurement the lane exists to make.
      provider_retry: false,
      # The deadline `execute/4` enforces, for the session to report: a model
      # is told how long it has only if the session knows (#35).
      deadline_ms: Keyword.get(opts, :timeout_ms, task.timeout_ms)
    ]

    session_opts =
      base
      |> Keyword.merge(Keyword.get(opts, :session_options, []))
      |> Keyword.merge(subscriber: self(), cwd: task.cwd)

    with :ok <- session_options(session_opts), do: Lemieux.start_session(session_opts)
  end

  # `Lemieux.start_session/1` raises in its caller for a provider or store
  # that is not a `{module, state}` pair, or no model: a host's mistake,
  # found where it was made. This module's contract is a result
  # (`t:Lemieux.Agent.result/0`), and `Lemieux.Agent.run/3` hands it on
  # unchanged, so the same mistakes are `{:error, reason}` here, as a missing
  # provider already was. Checked after `:session_options` is merged, since it
  # may replace any of the three, and reported by key, never by value:
  # providers and stores carry credentials in their state.
  defp session_options(session_opts) do
    Enum.find_value([:provider, :store, :model], :ok, fn key ->
      case {key, Keyword.get(session_opts, key)} do
        {_key, nil} -> {:error, {key, :required}}
        {:model, _model} -> nil
        {_pair, {module, _state}} when is_atom(module) and not is_nil(module) -> nil
        {_pair, _malformed} -> {:error, {key, :invalid}}
      end
    end)
  end

  defp execute(session, task, opts, supervisor) do
    id = Session.id(session)
    monitor = Process.monitor(session)
    timeout = Keyword.get(opts, :timeout_ms, task.timeout_ms)

    # A timer rather than a `receive ... after`, whose wait is always real
    # time: this way the deadline is whatever the clock says it is.
    clock = Keyword.get(opts, :clock)
    deadline = make_ref()
    timer = Clock.send_after(clock, self(), {:agent_deadline, deadline}, timeout)
    bound = {deadline, Keyword.get(opts, :timeout_reason, :agent_timeout)}

    try do
      case Session.prompt(session, task.prompt) do
        :ok -> await(session, id, monitor, bound, [], [])
        {:error, reason} -> {:error, {:prompt, reason}}
      end
    after
      Clock.cancel(clock, timer)
      flush_deadline(deadline)
      Process.demonitor(monitor, [:flush])
      DynamicSupervisor.terminate_child(Sup.session_supervisor(supervisor), session)
    end
  end

  # A deadline that fired as the run finished was not cancelled in time; its
  # message must not reach whatever this process does next.
  defp flush_deadline(deadline) do
    receive do
      {:agent_deadline, ^deadline} -> :ok
    after
      0 -> :ok
    end
  end

  defp await(
         session,
         id,
         monitor,
         {deadline, timeout_reason} = bound,
         direct_usages,
         delegated_usages
       ) do
    receive do
      {:lemieux, ^id, {:usage, usage}} ->
        await(session, id, monitor, bound, [usage | direct_usages], delegated_usages)

      {:lemieux, ^id, {:subagent, _path, {:usage, usage}}} ->
        await(session, id, monitor, bound, direct_usages, [usage | delegated_usages])

      {:lemieux, ^id, {:finished, reason}} ->
        observation(session, id, reason, direct_usages, delegated_usages)

      {:lemieux, ^id, _event} ->
        await(session, id, monitor, bound, direct_usages, delegated_usages)

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, {:session_died, reason}}

      {:agent_deadline, ^deadline} ->
        :ok = Session.cancel(session, timeout_reason)
        # cancel/2 is synchronous: the session checkpoints partial work before
        # replying. Drain usage it emitted before that reply, then snapshot it
        # before execute/4 terminates the session.
        {direct, delegated} = drain_usage(id, direct_usages, delegated_usages)
        observation(session, id, timeout_reason, direct, delegated)
    end
  end

  defp drain_usage(id, direct, delegated) do
    receive do
      {:lemieux, ^id, {:usage, usage}} ->
        drain_usage(id, [usage | direct], delegated)

      {:lemieux, ^id, {:subagent, _path, {:usage, usage}}} ->
        drain_usage(id, direct, [usage | delegated])

      {:lemieux, ^id, _event} ->
        drain_usage(id, direct, delegated)
    after
      0 -> {direct, delegated}
    end
  end

  defp observation(session, id, reason, direct, delegated) do
    snapshot = Session.snapshot(session)
    metrics = tool_metrics(snapshot.entries)
    measured = usage(direct, delegated)

    measured =
      if reason in [:benchmark_timeout, :agent_timeout] or
           measured["direct"]["requests"] != metrics["requests"] do
        measured
        |> Map.put("observed_cost_usd", measured["cost_usd"])
        |> Map.put("cost_usd", nil)
        |> put_in(["direct", "cost_usd"], nil)
      else
        measured
      end

    {:ok,
     %{
       "status" => if(reason in [:stop, :end_turn], do: "completed", else: "failed"),
       "answer" => answer(snapshot.entries),
       "finish_reason" => inspect(reason),
       "session_id" => id,
       "usage" => measured,
       "resources" => Resources.from_entries(snapshot.entries),
       "tool_metrics" => metrics,
       "provider_error" => provider_error(snapshot.entries),
       "transcript" => Enum.map(snapshot.entries, &entry/1)
     }}
  end

  # Every provider failure ends a run identically — stop reason `:error`, one error
  # entry — so a report recording only the finish reason could not say whether an
  # attempt measured the candidate or measured the network. The category is lifted
  # to the top of the observation because that is where a consumer with no
  # transcript can read it: the evaluation lane retries a timeout and never a wrong
  # answer. The HTTP status rides along (`nil` when the failure had none) so a
  # host's retry predicate can decide on the status itself — a 408 or an
  # empty-body 414 from a CDN — rather than retrying every `:other`. The
  # provider's code rides along the same way (`nil` without one): a
  # `"refused"` attempt says which policy refused it (#32).
  defp provider_error(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :error))
    |> case do
      nil ->
        nil

      %Entry{payload: payload} ->
        %{
          "category" => payload["category"],
          "reason" => payload["reason"],
          "http_status" => payload["http_status"],
          "code" => payload["code"]
        }
    end
  end

  defp answer(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :assistant))
    |> case do
      nil -> ""
      entry -> assistant_text(entry.payload)
    end
  end

  defp assistant_text(%{"content" => parts}) when is_list(parts) do
    parts
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join(&Map.get(&1, "text", ""))
  end

  defp assistant_text(_payload), do: ""

  defp usage(direct_usages, delegated_usages) do
    direct = usage(direct_usages)
    delegated = usage(delegated_usages)

    direct_usages
    |> Kernel.++(delegated_usages)
    |> usage()
    |> Map.put("direct", direct)
    |> Map.put("delegated", delegated)
  end

  defp usage(usages) do
    usages = Enum.reverse(usages)

    %{
      "requests" => length(usages),
      "input_tokens" => sum(usages, "input_tokens"),
      "output_tokens" => sum(usages, "output_tokens"),
      "cache_read_tokens" => sum(usages, "cache_read_tokens"),
      "cache_write_tokens" => sum(usages, "cache_write_tokens"),
      "cost_usd" => cost(usages)
    }
  end

  defp sum(usages, key),
    do: Enum.reduce(usages, 0, &(Map.get(&1, key, 0) + &2))

  defp cost(usages) do
    costs = Enum.map(usages, &Map.get(&1, "cost_usd"))

    if costs != [] and Enum.all?(costs, &is_number/1),
      do: Enum.sum(costs),
      else: nil
  end

  defp tool_metrics(entries) do
    requests = Enum.filter(entries, &(&1.type == :request))
    results = Enum.filter(entries, &(&1.type == :tool_result))
    token_counts = Enum.map(requests, &get_in(&1.payload, ["catalog", "token_count"]))
    costs = Enum.map(results, &get_in(&1.payload, ["cost", "usd"]))

    %{
      "requests" => length(requests),
      "catalog_bytes" => sum_payload(requests, ["catalog", "bytes"]),
      "catalog_tokens" => known_sum(token_counts),
      "tokenizers" =>
        requests
        |> Enum.map(&get_in(&1.payload, ["catalog", "tokenizer"]))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort(),
      "calls" => length(results),
      "errors" => Enum.count(results, &(&1.payload["error"] == true)),
      "denied" => Enum.count(results, &(&1.payload["outcome"] == "denied")),
      "unavailable" => Enum.count(results, &(&1.payload["outcome"] == "unavailable")),
      "timeouts" => Enum.count(results, &(&1.payload["outcome"] == "timeout")),
      "output_bytes" => sum_payload(results, ["output_bytes"]),
      "external_cost_usd" => known_sum(costs),
      "descriptor_digests" =>
        results
        |> Enum.map(& &1.payload["descriptor_digest"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort(),
      "profile_ids" =>
        requests
        |> Enum.map(&get_in(&1.payload, ["catalog", "profile", "id"]))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp sum_payload(entries, path) do
    Enum.reduce(entries, 0, fn entry, total ->
      case get_in(entry.payload, path) do
        value when is_number(value) -> total + value
        _unknown -> total
      end
    end)
  end

  defp known_sum([]), do: nil

  defp known_sum(values) do
    if Enum.all?(values, &is_number/1), do: Enum.sum(values), else: nil
  end

  defp entry(%Entry{} = entry), do: entry |> Entry.encode!() |> JSON.decode!()
end
