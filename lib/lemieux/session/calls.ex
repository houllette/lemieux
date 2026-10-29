defmodule Lemieux.Session.Calls do
  @moduledoc false

  alias Lemieux.Clock
  alias Lemieux.Input
  alias Lemieux.MCP
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.ModelSpec
  alias Lemieux.OpenTelemetry
  alias Lemieux.Provider
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Approvals
  alias Lemieux.Session.Aside
  alias Lemieux.Session.Boot
  alias Lemieux.Session.Catalog
  alias Lemieux.Session.Compacting
  alias Lemieux.Session.Core
  alias Lemieux.Session.Document
  alias Lemieux.Session.DocumentRequest
  alias Lemieux.Session.Instrumentation
  alias Lemieux.Session.MCPServers
  alias Lemieux.Session.Notification
  alias Lemieux.Session.Prompts
  alias Lemieux.Session.Recovery
  alias Lemieux.Session.Setup
  alias Lemieux.Session.Subscribers
  alias Lemieux.Session.ToolWave
  alias Lemieux.Tool
  alias Lemieux.Tool.Profile

  # Questions about the catalog wait while startup connections run, and are
  # answered when they settle: a count of zero for a server that is merely slow
  # is the wrong answer, and so is "no such tool" for one it is about to offer.
  # Snapshots, `info/1` and cancels are answered at once — they are how a host
  # stays responsive while it waits.
  def call(request, from, %{mcp_pending: pending} = state)
      when map_size(pending) > 0 and
             (request in [:mcp_status, :tool_status, :tool_catalog] or
                (is_tuple(request) and elem(request, 0) == :set_tool_access)),
      do: {:noreply, %{state | mcp_waiters: [{request, from} | state.mcp_waiters]}}

  def call(:contribution_context, _from, state),
    do: {:reply, {state.contribution_runtime, Boot.contribution_context(state)}, state}

  def call(:continue, _from, %{recovery_enabled?: false} = state),
    do: {:reply, {:error, :recovery_not_enabled}, state}

  def call(:continue, _from, state) do
    cond do
      Core.busy?(state) ->
        {:reply, {:error, :busy}, state}

      not Enum.any?(state.reversed_entries, &(&1.type == :user)) ->
        {:reply, {:error, :nothing_to_continue}, state}

      true ->
        calls = state.recovery_calls

        state =
          %{state | recovery_enabled?: false, recovery_calls: [], turns_taken: 0}
          |> Input.begin(:resumed_history, "")
          |> Prompts.begin_run()
          |> Instrumentation.start_prompt_telemetry()

        state = continue_restored(state, calls)

        {:reply, :ok, state}
    end
  end

  def call(:id, _from, state), do: {:reply, state.id, state}

  def call({:deliver_notification, event, opts}, _from, state),
    do: Notification.deliver(state, event, opts)

  def call({:subscribe, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscribers: Subscribers.add(state.subscribers, subscriber)}}
  end

  def call({:unsubscribe, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscribers: Subscribers.remove(state.subscribers, subscriber)}}
  end

  def call(:available_models, _from, state) do
    {:reply, Catalog.models(state), state}
  end

  def call(:model_metadata, _from, state) do
    {:reply, Provider.model_metadata(state.provider), state}
  end

  def call({:available_models, provider}, _from, state),
    do: {:reply, Catalog.models_for(state, provider), state}

  def call(:available_providers, _from, state) do
    providers =
      state |> Catalog.models() |> Enum.map(&ModelSpec.provider/1) |> Enum.reject(&is_nil/1)

    {:reply, Enum.uniq(providers), state}
  end

  def call(:fast_modes, _from, state),
    do: {:reply, Provider.fast_modes(state.provider, state.model), state}

  def call({:set_fast_mode, _mode}, _from, state) when not is_nil(state.turn),
    do: {:reply, {:error, :busy}, state}

  def call({:set_fast_mode, mode}, _from, state) do
    if Core.busy?(state),
      do: {:reply, {:error, :busy}, state},
      else: Catalog.change_fast_mode(state, mode)
  end

  def call(:reasoning_efforts, _from, state),
    do: {:reply, Provider.reasoning_efforts(state.provider, state.model), state}

  def call({:set_model, _model}, _from, state) when not is_nil(state.turn),
    do: {:reply, {:error, :busy}, state}

  def call({:set_model, model}, _from, state) do
    cond do
      Core.busy?(state) ->
        {:reply, {:error, :busy}, state}

      model == state.model ->
        {:reply, {:ok, model}, state}

      true ->
        Catalog.change_model(state, model)
    end
  end

  def call({:set_provider, _provider}, _from, state) when not is_nil(state.turn),
    do: {:reply, {:error, :busy}, state}

  def call({:set_provider, provider}, _from, state) do
    provider = provider |> String.trim() |> String.downcase()

    cond do
      Core.busy?(state) ->
        {:reply, {:error, :busy}, state}

      provider == ModelSpec.provider(state.model) ->
        {:reply, {:ok, state.model}, state}

      true ->
        case Catalog.models_for(state, provider) do
          [model | _rest] -> Catalog.change_model(state, model)
          [] -> {:reply, {:error, {:provider_unavailable, provider}}, state}
        end
    end
  end

  def call({:set_reasoning_effort, _effort}, _from, state) when not is_nil(state.turn),
    do: {:reply, {:error, :busy}, state}

  def call({:set_reasoning_effort, effort}, _from, state) do
    effort = effort |> String.trim() |> String.downcase()

    cond do
      Core.busy?(state) ->
        {:reply, {:error, :busy}, state}

      effort == "default" ->
        Catalog.change_reasoning_effort(state, nil)

      effort in Provider.reasoning_efforts(state.provider, state.model) ->
        Catalog.change_reasoning_effort(state, effort)

      true ->
        supported = Provider.reasoning_efforts(state.provider, state.model)

        {:reply, {:error, {:reasoning_effort_unsupported, state.model, effort, supported}}, state}
    end
  end

  def call({:set_tools, _tools}, _from, state) when not is_nil(state.turn),
    do: {:reply, {:error, :busy}, state}

  def call({:set_tools, configured_tools}, _from, state) do
    if Core.busy?(state) do
      {:reply, {:error, :busy}, state}
    else
      local_tools = configured_tools ++ state.host_tools
      remote_tools = Enum.filter(Catalog.tool_catalog(state), &match?(%RemoteTool{}, &1))

      reset_names =
        state.local_tools
        |> Kernel.++(local_tools)
        |> MapSet.new(&Tool.name/1)

      disabled_tools = MapSet.difference(state.disabled_tools, reset_names)

      with :ok <- Tool.validate_all(local_tools),
           disallowed = Catalog.tool_denials(state.tool_profile, local_tools),
           [] <- disallowed,
           tools =
             Catalog.enabled_tools(
               local_tools ++ remote_tools,
               disabled_tools,
               state.tool_profile
             ),
           :ok <- Tool.validate_all(tools),
           :ok <- Provider.validate_model(state.provider, state.model, tools) do
        previous = Catalog.local_tool_names(state)
        names = Enum.map(local_tools, &Tool.name/1)
        configured_names = Enum.map(configured_tools, &Tool.name/1)

        state =
          state
          |> Map.put(:configured_tools, configured_tools)
          |> Core.forget_assembly()
          |> Map.put(:local_tools, local_tools)
          |> Map.put(:disabled_tools, disabled_tools)
          |> Map.put(:tools, tools)
          |> Setup.record_config()
          |> Core.append(Setup.tool_profile_notice(state, tools))
          |> Core.emit({:tools_changed, previous, configured_names})

        {:reply, {:ok, names}, state}
      else
        names when is_list(names) -> {:reply, {:error, {:tools_disallowed, names}}, state}
        {:error, _reason} = error -> {:reply, error, state}
      end
    end
  end

  def call(:tool_status, _from, state), do: {:reply, Catalog.tool_statuses(state), state}

  def call(:tools, _from, state), do: {:reply, state.local_tools, state}

  def call({:tool_decision, tool}, _from, state),
    do: {:reply, Profile.decision(state.tool_profile, tool), state}

  def call({:set_tool_access, _names, _enabled?}, _from, state)
      when not is_nil(state.turn),
      do: {:reply, {:error, :busy}, state}

  def call({:set_tool_access, names, enabled?}, _from, state) do
    names = Enum.uniq(names)
    catalog = Catalog.tool_catalog(state)
    available = MapSet.new(catalog, &Tool.name/1)
    unknown = Enum.reject(names, &MapSet.member?(available, &1))

    disallowed =
      catalog
      |> Enum.filter(&(Tool.name(&1) in names))
      |> then(&Catalog.tool_denials(state.tool_profile, &1))
      |> Enum.uniq_by(&elem(&1, 0))

    cond do
      Core.busy?(state) ->
        {:reply, {:error, :busy}, state}

      unknown != [] ->
        {:reply, {:error, {:unknown_tools, unknown}}, state}

      enabled? and disallowed != [] ->
        {:reply, {:error, {:tools_disallowed, disallowed}}, state}

      true ->
        disabled_tools = Catalog.update_disabled_tools(state.disabled_tools, names, enabled?)
        Catalog.change_tool_access(state, catalog, names, disabled_tools, enabled?)
    end
  end

  def call(:snapshot, _from, state) do
    context = Compacting.context(state)
    usage = Accounting.usage_summary(state, context)

    snapshot = %{
      id: state.id,
      status: Core.status(state),
      model: state.model,
      provider: ModelSpec.provider(state.model),
      reasoning_effort: Catalog.reasoning_effort(state) || "default",
      reasoning_efforts: Provider.reasoning_efforts(state.provider, state.model),
      fast_mode: Keyword.get(state.params, :fast_mode, "off"),
      fast_modes: Provider.fast_modes(state.provider, state.model),
      tools: Catalog.local_tool_names(state),
      cwd: state.cwd,
      pending: Core.pending(state),
      queued_steers: Enum.reverse(state.reversed_steers),
      queued_follow_ups: Enum.map(Enum.reverse(state.reversed_follow_ups), &Input.queued_text/1),
      request_id: state.current_request_id,
      spent_usd: state.spent_usd,
      inclusive_spent_usd: usage.total["cost_usd"],
      usage: usage,
      max_cost_usd: state.max_cost_usd,
      harness_snapshot: state.evidence.current_harness_snapshot,
      run_evidence: state.evidence.last_run_evidence,
      entries: Core.entries(state),
      context: context,
      # What a caller composing a request on this session's behalf needs to
      # know and cannot read off the transcript: the generation parameters in
      # force, the host's own harness context, and the runtime the session is
      # mounted in. `Lemieux.Reflection.reflect/2` sizes its evidence from the
      # first two; `Lemieux.Eval` finds the session's evaluation node with
      # the third.
      params: state.params,
      harness_context: state.evidence.harness_context,
      supervisor: state.supervisor
    }

    {:reply, snapshot, state}
  end

  def call(:info, _from, state) do
    context = Compacting.context(state)

    info = %{
      id: state.id,
      status: Core.status(state),
      model: state.model,
      provider: ModelSpec.provider(state.model),
      reasoning_effort: Catalog.reasoning_effort(state) || "default",
      reasoning_efforts: Provider.reasoning_efforts(state.provider, state.model),
      fast_mode: Keyword.get(state.params, :fast_mode, "off"),
      fast_modes: Provider.fast_modes(state.provider, state.model),
      tools: Catalog.local_tool_names(state),
      cwd: state.cwd,
      pending: Core.pending(state),
      queued_steers: Enum.reverse(state.reversed_steers),
      queued_follow_ups: Enum.map(Enum.reverse(state.reversed_follow_ups), &Input.queued_text/1),
      request_id: state.current_request_id,
      requests: state.request_count,
      max_requests: state.max_requests,
      job: Lemieux.JobBudget.snapshot(state.job_budget),
      spent_usd: state.spent_usd,
      max_cost_usd: state.max_cost_usd,
      usage: Accounting.usage_summary(state, context),
      context: context,
      context_window_known?: is_integer(state.context_window),
      ready?: state.mcp_ready?,
      supervisor: state.supervisor,
      mcp: MCPServers.mcp_server_statuses(state)
    }

    {:reply, info, state}
  end

  def call(:tool_catalog, _from, state), do: {:reply, state.tools, state}

  def call(:budget, _from, state) do
    budget = %{
      spent_usd: state.spent_usd,
      max_cost_usd: state.max_cost_usd,
      requests: state.request_count,
      max_requests: state.max_requests,
      deadline_ms: state.deadline_ms,
      job: Lemieux.JobBudget.snapshot(state.job_budget),
      time_left_ms: time_left(state)
    }

    {:reply, budget, state}
  end

  def call(:checkpoint_job_budget, _from, %{job_budget_owned?: false} = state),
    do: {:reply, :ok, state}

  def call(:checkpoint_job_budget, _from, state),
    do: {:reply, :ok, Accounting.checkpoint_job(state)}

  def call({:document, namespace}, _from, state),
    do: {:reply, Document.read(state.reversed_entries, namespace), state}

  def call({:put_document, namespace, expected, value, usage}, _from, state) do
    case Document.read(state.reversed_entries, namespace) do
      {:ok, %{revision: ^expected}} ->
        revision = expected + 1

        payload = %{
          "version" => 1,
          "namespace" => namespace,
          "revision" => revision,
          "value" => value
        }

        state = Core.append(state, {:extension_state, payload, usage})
        state = if is_map(usage), do: Accounting.account_external_usage(state, usage), else: state
        state = if is_map(usage), do: Core.emit(state, {:usage, usage}), else: state
        {:reply, {:ok, %{revision: revision, value: value}}, state}

      {:ok, %{revision: revision}} ->
        state =
          if is_map(usage) do
            payload = %{
              "version" => 1,
              "namespace" => "$external_usage",
              "revision" => 1,
              "value" => %{"source" => namespace, "conflict_revision" => revision}
            }

            state
            |> Core.append({:extension_state, payload, usage})
            |> Accounting.account_external_usage(usage)
            |> Core.emit({:usage, usage})
          else
            state
          end

        {:reply, {:error, {:conflict, revision}}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def call(:delegation_context, _from, state) do
    context = %{
      id: state.id,
      root_session_id: state.root_session_id,
      supervisor: state.supervisor,
      provider: state.provider,
      provider_limiter: state.provider_limiter,
      provider_limit_key: state.provider_limit_key,
      job_budget: state.job_budget,
      execution: state.execution,
      store: state.store,
      cwd: state.cwd,
      environment: state.environment,
      hooks: state.hooks
    }

    {:reply, context, state}
  end

  def call({:work_context, namespaces}, _from, state) do
    # Hosts need recent work identities, not a copy of every request and file
    # in the conversation. Live owners are discovery, never control tokens.
    entries =
      state.reversed_entries
      |> Stream.filter(&work_entry?(&1, namespaces))
      |> Enum.take(512)
      |> Enum.reverse()

    {:reply,
     %{
       id: state.id,
       supervisor: state.supervisor,
       owners: state.subagent_groups,
       entries: entries
     }, state}
  end

  def call({:append_subagent_entry, type, payload}, _from, state) do
    state = Core.append(state, {type, payload, nil})
    state = Accounting.checkpoint_job(state)

    {:reply, {:ok, List.first(state.reversed_entries)}, Catalog.delegated_settled(state, type)}
  end

  def call({:register_subagent_group, group_id, group}, _from, state) do
    {:reply, :ok, put_in(state.subagent_groups[group_id], group)}
  end

  def call({:register_work_owner, id, _owner}, _from, %{subagent_groups: groups} = state)
      when is_map_key(groups, id),
      do: {:reply, {:error, :already_registered}, state}

  def call({:register_work_owner, id, owner}, _from, state) do
    ref = Process.monitor(owner)

    state = %{
      state
      | subagent_groups: Map.put(state.subagent_groups, id, owner),
        work_owner_monitors: Map.put(state.work_owner_monitors, ref, id)
    }

    {:reply, :ok, state}
  end

  def call({:unregister_work_owner, id, owner}, _from, state)
      when not is_map_key(state.subagent_groups, id) or
             :erlang.map_get(id, state.subagent_groups) == owner do
    {removed, kept} = Enum.split_with(state.work_owner_monitors, fn {_ref, key} -> key == id end)
    Enum.each(removed, fn {ref, _id} -> Process.demonitor(ref, [:flush]) end)

    {:reply, :ok,
     %{
       state
       | subagent_groups: Map.delete(state.subagent_groups, id),
         work_owner_monitors: Map.new(kept)
     }}
  end

  def call({:unregister_work_owner, _id, _owner}, _from, state),
    do: {:reply, {:error, :owner_changed}, state}

  def call({:unregister_subagent_group, group_id}, _from, state) do
    {:reply, :ok, %{state | subagent_groups: Map.delete(state.subagent_groups, group_id)}}
  end

  def call(:mcp_clients, _from, state),
    do: {:reply, MCPServers.connected_clients(state), state}

  def call(:mcp_status, _from, state), do: {:reply, MCPServers.mcp_statuses(state), state}

  def call({:set_mcp_enabled, name, enabled?}, _from, state) do
    cond do
      Core.busy?(state) ->
        {:reply, {:error, :busy}, state}

      not Enum.any?(state.mcp_servers, &(Map.fetch!(&1, "name") == name)) ->
        {:reply, {:error, :unknown_server}, state}

      MapSet.member?(state.mcp_disabled, name) != enabled? ->
        {:reply, :ok, state}

      true ->
        {:reply, :ok, MCPServers.change_mcp_enabled(state, name, enabled?)}
    end
  end

  def call({:add_mcp_servers, servers}, _from, state) do
    if Core.busy?(state) do
      {:reply, {:error, :busy}, state}
    else
      configs = servers |> Enum.map(&MCP.config/1) |> Setup.merge_mcp_servers([])
      names = MapSet.new(configs, &Map.fetch!(&1, "name"))
      state = MCPServers.forget_mcp_connecting(state, MapSet.to_list(names))
      {state, connections, errors} = MCPServers.connect_mcp_servers(state, configs)

      state =
        state
        |> MCPServers.disconnect_mcp_connections(names)
        |> Map.update!(:mcp_connections, &Map.merge(&1, connections))
        |> Map.update!(:mcp_errors, &(&1 |> Map.drop(MapSet.to_list(names)) |> Map.merge(errors)))
        |> Map.put(:mcp_servers, Setup.merge_mcp_servers(configs, state.mcp_servers))
        |> MCPServers.refresh_mcp_tools()
        |> Setup.record_config()

      {:reply, :ok, state}
    end
  end

  def call({:remove_mcp_server, name}, _from, state) do
    cond do
      Core.busy?(state) ->
        {:reply, {:error, :busy}, state}

      not Enum.any?(state.mcp_servers, &(Map.fetch!(&1, "name") == name)) ->
        {:reply, {:error, :unknown_server}, state}

      true ->
        state =
          state
          |> MCPServers.forget_mcp_connecting([name])
          |> MCPServers.disconnect_mcp_connections(MapSet.new([name]))
          |> Map.update!(:mcp_servers, &Enum.reject(&1, fn config -> config["name"] == name end))
          |> Map.update!(:mcp_errors, &Map.delete(&1, name))
          |> Map.update!(:mcp_disabled, &MapSet.delete(&1, name))
          |> MCPServers.refresh_mcp_tools()
          |> Setup.record_config()

        {:reply, :ok, state}
    end
  end

  def call({:reconnect_mcp, name}, _from, state) when is_binary(name) do
    config = Enum.find(state.mcp_servers, &(Map.fetch!(&1, "name") == name))

    cond do
      Core.busy?(state) ->
        {:reply, {:error, :busy}, state}

      is_nil(config) ->
        {:reply, {:error, :unknown_server}, state}

      MapSet.member?(state.mcp_disabled, name) ->
        {:reply, {:error, :server_disabled}, state}

      true ->
        state = MCPServers.forget_mcp_connecting(state, [name])

        {state, connections, errors} =
          MCPServers.connect_mcp_servers(state, [config], interactive_auth: true)

        state =
          state
          |> MCPServers.disconnect_mcp_connections(MapSet.new([name]))
          |> Map.update!(:mcp_connections, &Map.merge(&1, connections))
          |> Map.update!(:mcp_errors, &(&1 |> Map.delete(name) |> Map.merge(errors)))
          |> MCPServers.refresh_mcp_tools()

        {:reply, :ok, state}
    end
  end

  def call({:reconnect_mcp, :all}, _from, state) do
    if Core.busy?(state) do
      {:reply, {:error, :busy}, state}
    else
      names = MapSet.new(state.mcp_servers, &Map.fetch!(&1, "name"))
      state = MCPServers.forget_mcp_connecting(state, MapSet.to_list(names))

      {state, connections, errors} =
        MCPServers.connect_mcp_servers(state, state.mcp_servers, interactive_auth: true)

      state =
        state
        |> MCPServers.disconnect_mcp_connections(names)
        |> Map.put(:mcp_connections, connections)
        |> Map.put(:mcp_errors, errors)
        |> MCPServers.refresh_mcp_tools()

      {:reply, :ok, state}
    end
  end

  def call({:prompt, text, contexts}, from, state),
    do: call({:prompt, text, contexts, []}, from, state)

  def call({:input_original, id, token}, _from, state),
    do: {:reply, Input.read(state, id, token), state}

  def call({:prompt, text, contexts, opts}, from, state) do
    if Core.busy?(state) do
      {:reply, {:error, :busy}, state}
    else
      case Input.attest(state, from, :prompt, opts) do
        {:ok, attestation} ->
          OpenTelemetry.bind_prompt_parent(state.id, contexts)
          Prompts.start_prompt_hook(state, from, text, attestation)

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  end

  # The same path as a prompt from here on, with the aside on the state for
  # `start_turn/1` to read; it is cleared when the run ends or the prompt hook
  # refuses it. Its text is the prompt: the hook sees what the model will.
  def call({:aside, %Aside{} = aside, contexts}, from, state) do
    if Core.busy?(state) do
      {:reply, {:error, :busy}, state}
    else
      OpenTelemetry.bind_prompt_parent(state.id, contexts)
      Prompts.start_prompt_hook(%{state | aside: aside}, from, aside.text)
    end
  end

  def call({:generate_document, namespace, revision, request, build, opts}, from, state),
    do:
      DocumentRequest.start(
        state,
        from,
        namespace,
        revision,
        request,
        build,
        opts
      )

  def call(:compact, from, state) do
    # No reply on the second branch: it is answered when the summarising
    # request comes back, the same way a parked tool call is.
    if Core.busy?(state),
      do: {:reply, {:error, :busy}, state},
      else: Compacting.start_compacting(state, from)
  end

  def call({:advise_compaction, advice}, _from, state) do
    if Compacting.valid_compaction_advice?(advice) do
      {:reply, :ok, Core.put_compaction(state, :advice, advice)}
    else
      {:reply, {:error, :invalid_advice}, state}
    end
  end

  def call(:clear, _from, state) do
    if Core.busy?(state),
      do: {:reply, {:error, :busy}, state},
      else: Compacting.clear_context(state)
  end

  # The call's own deadline stops while it waits for somebody. It used to keep
  # running: a `write` parked for approval had two minutes, so a person who took
  # three to decide found the call already timed out — and their "yes" recorded
  # as an approval of a call that never ran.
  def call({:park, call_id, kind, payload, opts}, from, state),
    do: Approvals.park(state, from, call_id, kind, payload, opts)

  def call({:approval_request, call_id}, _from, state),
    do: {:reply, Approvals.request_for(state, call_id), state}

  def call({:resolve_approval, request, decision, opts}, from, state),
    do: Approvals.resolve_scoped(state, from, request, decision, opts)

  def call({:resolve, call_id, resolution}, _from, state),
    do: Approvals.resolve_legacy(state, call_id, resolution)

  def call({:steer, text}, _from, state) do
    {:reply, :ok, %{state | reversed_steers: [text | state.reversed_steers]}}
  end

  def call({:revoke_steer, text}, _from, state) do
    case List.delete(state.reversed_steers, text) do
      same when same == state.reversed_steers -> {:reply, {:error, :already_sent}, state}
      remaining -> {:reply, :ok, %{state | reversed_steers: remaining}}
    end
  end

  def call(:refresh, from, state) do
    if Core.busy?(state) do
      {:reply, {:error, :busy}, state}
    else
      Prompts.start_refresh(state, from)
    end
  end

  def call({:follow_up, text}, from, state), do: call({:follow_up, text, []}, from, state)

  def call({:follow_up, text, opts}, from, state) do
    case Input.attest(state, from, :follow_up, opts) do
      {:ok, attestation} ->
        submission = {text, attestation}

        if Core.busy?(state),
          do:
            {:reply, :ok,
             %{state | reversed_follow_ups: [submission | state.reversed_follow_ups]}},
          else: {:reply, :ok, Prompts.start_follow_up_hook(state, submission)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def call({:cancel, reason}, _from, state) do
    if Core.busy?(state),
      do: {:reply, :ok, Prompts.do_cancel(state, reason)},
      else: {:reply, :ok, state}
  end

  def call(:retry, _from, state) do
    cond do
      Core.busy?(state) ->
        {:reply, {:error, :busy}, state}

      not Recovery.retryable_stop?(state) ->
        {:reply, {:error, :nothing_to_retry}, state}

      true ->
        state =
          state
          |> Prompts.begin_run()
          |> Map.merge(%{retry_attempt: 0, retry_note: nil, stop_hook_active: false})
          |> Instrumentation.start_prompt_telemetry()
          |> Compacting.continue()

        {:reply, :ok, state}
    end
  end

  def cast({:publish_subagent_event, event}, state),
    do: {:noreply, Core.emit(state, event)}

  defp work_entry?(%{type: type}, _namespaces) when type in [:subagent_spawn, :subagent_result],
    do: true

  defp work_entry?(%{type: :extension_state, payload: %{"namespace" => namespace}}, namespaces),
    do: String.starts_with?(namespace, namespaces)

  defp work_entry?(_entry, _namespaces), do: false

  # What is left of the host's deadline, never less than nothing.
  defp time_left(%{deadline_at: nil}), do: nil
  defp time_left(state), do: max(state.deadline_at - Clock.now_ms(state.clock), 0)

  defp continue_restored(%{recovery_stop: reason} = state, _calls) when not is_nil(reason),
    do: Prompts.start_stop_hook(state, reason)

  defp continue_restored(state, []), do: Compacting.continue(state)
  defp continue_restored(state, calls), do: ToolWave.apply_effect(state, {:run_tools, calls})
end
