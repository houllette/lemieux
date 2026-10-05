defmodule Lemieux.Subagent do
  @moduledoc """
  Depth-one, bounded, read-only delegation owned by a parent session.

  This is intentionally not a general multi-agent framework. A parent reserves
  one foreground group, one to three ordinary `Lemieux.Session` children read
  an explicit snapshot through certified read-only tools, and an ordered
  all-settled result returns to the parent. Children cannot receive the
  `delegate` tool, broaden their authority, survive as background peers, or
  write to the shared checkout.

  `spawn/4` and `spawn_many/3` return after durable spawn intents and atomic
  admission, not after model work. `await/2` is only a convenience over the
  addressable group; it never owns child lifetime. Refs contain an unforgeable
  live control capability in addition to public transcript ids, because a pid
  or id by itself is not authorization.
  """

  alias Lemieux.OpenTelemetry
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Group
  alias Lemieux.Subagent.Group.Ref, as: GroupRef
  alias Lemieux.Subagent.Ref
  alias Lemieux.Subagent.Replay
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Snapshot
  alias Lemieux.Subagent.Task
  alias Lemieux.Supervisor, as: Sup

  @default_fan_out 3
  @hard_fan_out 4

  @doc "Starts one child and returns its addressable ref."
  @spec spawn(
          parent :: Session.session() | String.t(),
          definition :: Definition.t(),
          task :: Task.t(),
          opts :: keyword()
        ) :: {:ok, Ref.t()} | {:error, term()}
  def spawn(parent, %Definition{} = definition, %Task{} = task, opts \\ []) do
    with {:ok, group_ref} <- spawn_many(parent, [Request.new(definition, task)], opts),
         {:ok, [child_ref]} <- children(group_ref) do
      {:ok, child_ref}
    end
  end

  @doc """
  Starts an atomically admitted, input-ordered fan-out.

  Returns once the reservation holds and the spawn intents are durable, not
  once the children have answered — `await/2` is for that.

  Required: `:max_cost_usd`, the whole tree's allowance.

  Optional:

    * `:timeout` — the group's own hard deadline, one hour by default. It
      is a ceiling on waiting, not the guard against a stuck child: that is
      the check below and the budgets.
    * `:deadline_ms` — a host allowance composed with the group's. The
      effective deadline is the shorter of the two, it is persisted in each
      spawn intent with its source, and every child's hard clock is clamped
      to what is left of it. A definition's own `timeout` cannot extend it.
    * `:progress` — who decides at a child's soft deadline, which fires
      every `progress_interval` of its definition. `assess: :model` (the
      default) settles the clear cases from the transcript and asks a model
      about the rest; `assess: :activity` never asks; `assess: false` arms
      no checks, so the hard deadline is the only clock; a one-argument
      function is the host's own assessor. `:provider` and `:model` name
      the judge (the child's own by default) and `:timeout_ms` bounds one
      judge request. See `Lemieux.Progress`.
    * `:cancel_grace_ms` — how long a cancelled child is given to checkpoint
      before the group stops waiting for it (default five seconds).
    * `:clock` — the `Lemieux.Clock` the group's deadline, its children's
      clocks, their progress checks and the cancel grace are measured on.
      The real clock when omitted; a test passes a `Lemieux.Clock.Manual`
      and moves time itself.
    * `:authorize` — `(action, context -> :ok | {:error, reason})`, consulted
      after the capability token on every control call. See
      `Lemieux.Subagent.Group.authorized_actions/0` for the vocabulary.
    * `:max_fan_out` — lower the four-child ceiling.
    * `:providers`, `:provider_factory`, `:child_options`, `:policy` — what
      each child session is built from.
  """
  @spec spawn_many(
          parent :: Session.session() | String.t(),
          requests :: [Request.t()],
          opts :: keyword()
        ) :: {:ok, GroupRef.t()} | {:error, term()}
  def spawn_many(parent, requests, opts \\ []) when is_list(requests) and is_list(opts) do
    with :ok <- validate_batch(requests, opts),
         {:ok, max_cost_usd} <- tree_budget(opts),
         {:ok, parent} <- resolve_parent(parent, opts),
         context <- Session.delegation_context(parent),
         {:ok, group} <- start_group(parent, context.supervisor, requests, max_cost_usd, opts) do
      {:ok, Group.group_ref(group)}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Lists child refs in the same order the group request used."
  @spec children(group_ref :: GroupRef.t()) :: {:ok, [Ref.t()]} | {:error, term()}
  def children(%GroupRef{} = ref) do
    with {:ok, group} <- group(ref) do
      Group.child_refs(group, ref.control_token)
    end
  end

  @doc "Awaits a child or group terminal result without owning its lifetime."
  @spec await(ref :: Ref.t() | GroupRef.t(), timeout()) :: {:ok, term()} | {:error, term()}
  def await(ref, timeout \\ :infinity)

  def await(%GroupRef{} = ref, timeout) do
    case group(ref) do
      {:ok, group} ->
        live_call(group, fn -> Group.await(group, ref.control_token, timeout) end, fn ->
          durable_group_result(ref)
        end)

      {:error, :not_running} ->
        durable_group_result(ref)
    end
  end

  def await(%Ref{} = ref, timeout) do
    case group(ref) do
      {:ok, group} ->
        live_call(
          group,
          fn -> Group.await_child(group, ref.control_token, ref.id, timeout) end,
          fn ->
            durable_child_result(ref)
          end
        )

      {:error, :not_running} ->
        durable_child_result(ref)
    end
  end

  @doc "Returns a bounded live snapshot of one child."
  @spec inspect(ref :: Ref.t()) :: {:ok, Lemieux.Subagent.Snapshot.t()} | {:error, term()}
  def inspect(%Ref{} = ref) do
    case group(ref) do
      {:ok, group} ->
        live_call(group, fn -> Group.inspect_child(group, ref.control_token, ref.id) end, fn ->
          durable_snapshot(ref)
        end)

      {:error, :not_running} ->
        durable_snapshot(ref)
    end
  end

  @doc "Durably steers one running child without changing its authority."
  @spec steer(ref :: Ref.t(), instruction :: String.t()) :: :ok | {:error, term()}
  def steer(%Ref{} = ref, instruction) when is_binary(instruction) do
    with {:ok, group} <- group(ref) do
      Group.steer_child(group, ref.control_token, ref.id, instruction)
    end
  end

  @doc """
  Cancels one child or an entire group while retaining completed siblings.

  `reason` is the caller's own words for why, and it reaches the cancelled
  child's terminal envelope rather than being discarded at the boundary: every
  cancellation used to look identical whatever provoked it. Children are
  cancelled concurrently and given a bounded grace interval to checkpoint;
  this returns when the last one is terminal or when that interval expires.
  """
  @spec cancel(ref :: Ref.t() | GroupRef.t(), reason :: term()) :: :ok | {:error, term()}
  def cancel(ref, reason \\ :cancelled)

  def cancel(%GroupRef{} = ref, reason) do
    with {:ok, group} <- group(ref) do
      Group.cancel(group, ref.control_token, reason)
    end
  end

  def cancel(%Ref{} = ref, reason) do
    with {:ok, group} <- group(ref) do
      Group.cancel_child(group, ref.control_token, ref.id, reason)
    end
  end

  @doc false
  @spec group(ref :: Ref.t() | GroupRef.t()) :: {:ok, pid()} | {:error, :not_running}
  def group(%{supervisor: supervisor, group_id: group_id}), do: lookup(supervisor, group_id)
  def group(%GroupRef{supervisor: supervisor, id: group_id}), do: lookup(supervisor, group_id)

  defp lookup(supervisor, group_id) do
    case Registry.lookup(Sup.registry(supervisor), {:subagent_group, group_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_running}
    end
  end

  defp durable_group_result(ref) do
    with {:ok, store} <- parent_store(ref.supervisor, ref.parent_id) do
      Replay.group_result(store, ref.parent_id, ref.id)
    end
  end

  defp durable_child_result(ref) do
    with {:ok, store} <- parent_store(ref.supervisor, ref.parent_id) do
      Replay.child_result(store, ref.parent_id, ref.id)
    end
  end

  defp durable_snapshot(ref) do
    with {:ok, store} <- parent_store(ref.supervisor, ref.parent_id),
         {:ok, result} <- Replay.child_result(store, ref.parent_id, ref.id) do
      {:ok,
       %Snapshot{
         id: ref.id,
         group_id: ref.group_id,
         parent_id: ref.parent_id,
         status: result.status,
         definition_id: result.definition_id,
         transcript_id: result.transcript_id,
         input: durable_input(store, ref),
         session: running_child_snapshot(ref),
         result: result
       }}
    end
  end

  defp durable_input(store, ref) do
    parent_entries = read_entries(store, ref.parent_id)
    child_entries = read_entries(store, ref.id)

    spawn =
      Enum.find(parent_entries, fn entry ->
        entry.type == :subagent_spawn and entry.payload["child_id"] == ref.id
      end)

    session = Enum.find(child_entries, &(&1.type == :session))
    user = Enum.find(child_entries, &(&1.type == :user))
    request = Enum.find(child_entries, &(&1.type == :request))

    %{
      "definition_id" => payload(spawn, "definition_id"),
      "definition_digest" => payload(spawn, "definition_digest"),
      "model" => payload(session, "model"),
      "tools" => payload(session, "tools"),
      "task" => payload(spawn, "task"),
      "system_prompt" => payload(session, "system"),
      "user_prompt" => payload(user, "text"),
      "request" => if(request, do: request.payload)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp read_entries(store, id) do
    case Store.read(store, id) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  defp payload(nil, _key), do: nil
  defp payload(entry, key), do: entry.payload[key]

  defp live_call(group, call, fallback) do
    call.()
  catch
    :exit, reason -> if(Process.alive?(group), do: exit(reason), else: fallback.())
  end

  defp parent_store(supervisor, parent_id) do
    case Lemieux.session(supervisor, parent_id) do
      {:ok, parent} -> {:ok, Session.delegation_context(parent).store}
      :error -> {:error, :not_running}
    end
  end

  defp running_child_snapshot(ref) do
    case Lemieux.session(ref.supervisor, ref.id) do
      {:ok, session} -> Session.snapshot(session)
      :error -> nil
    end
  end

  defp start_group(parent, supervisor, requests, max_cost_usd, opts) do
    id_generator = Keyword.get(opts, :id_generator, &Lemieux.ID.generate/0)
    group_id = id_generator.()
    child_ids = Enum.map(requests, fn _request -> id_generator.() end)
    control_token = make_ref()

    group_opts =
      opts
      |> Keyword.drop([:max_fan_out, :id_generator])
      |> Keyword.merge(
        id: group_id,
        child_ids: child_ids,
        control_token: control_token,
        parent: parent,
        requests: requests,
        supervisor: supervisor,
        max_cost_usd: max_cost_usd,
        open_telemetry_parent_contexts: OpenTelemetry.capture_contexts()
      )

    DynamicSupervisor.start_child(Sup.subagent_group_supervisor(supervisor), {Group, group_opts})
  end

  defp resolve_parent(parent, _opts) when is_pid(parent) do
    if Process.alive?(parent), do: {:ok, parent}, else: {:error, :parent_not_running}
  end

  defp resolve_parent(parent_id, opts) when is_binary(parent_id) do
    supervisor = Keyword.get(opts, :supervisor, Sup)

    case Lemieux.session(supervisor, parent_id) do
      {:ok, parent} -> {:ok, parent}
      :error -> {:error, :parent_not_running}
    end
  end

  defp resolve_parent(_parent, _opts), do: {:error, :invalid_parent}

  defp validate_batch(requests, opts) do
    configured_fan_out = Keyword.get(opts, :max_fan_out, @default_fan_out)

    cond do
      not is_integer(configured_fan_out) or configured_fan_out <= 0 ->
        {:error, :invalid_fan_out_limit}

      requests == [] ->
        {:error, :empty_group}

      length(requests) > min(configured_fan_out, @hard_fan_out) ->
        {:error, {:fan_out_limit, min(configured_fan_out, @hard_fan_out)}}

      Enum.all?(requests, &match?(%Request{}, &1)) ->
        validate_requests(requests)

      true ->
        {:error, :invalid_request}
    end
  end

  defp validate_requests(requests) do
    Enum.each(requests, fn request ->
      Definition.validate!(request.definition)
      Task.validate!(request.task)
    end)

    :ok
  end

  defp tree_budget(opts) do
    case Keyword.fetch(opts, :max_cost_usd) do
      {:ok, value} when is_number(value) and value > 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_tree_budget, value}}
      :error -> {:error, :tree_budget_required}
    end
  end
end
