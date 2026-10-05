defmodule Lemieux.Session.Catalog do
  @moduledoc false

  alias Lemieux.MCP
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.ModelSpec
  alias Lemieux.Provider
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Session.Compacting
  alias Lemieux.Session.Core
  alias Lemieux.Session.Setup
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Profile

  def local_tool_names(state) do
    state.tool_profile
    |> Profile.filter(state.local_tools)
    |> Enum.map(&Tool.name/1)
  end

  def tool_catalog(state), do: state.local_tools ++ remote_tools(state)

  # Every enabled server's tools, with names settled across servers by
  # `Lemieux.MCP.disambiguate/1`: two servers offering a tool that sanitises to
  # the same name must not reach a provider as one name for two tools.
  def remote_tools(state) do
    state.mcp_servers
    |> Enum.flat_map(fn config ->
      {tools, _clients} = Map.get(state.mcp_connections, config["name"], {[], []})
      if MapSet.member?(state.mcp_disabled, config["name"]), do: [], else: tools
    end)
    |> MCP.disambiguate()
  end

  def tool_statuses(state) do
    Enum.map(tool_catalog(state), fn tool ->
      allowed? = Profile.allowed?(state.tool_profile, tool)

      %{
        name: Tool.name(tool),
        source: tool_source(tool),
        allowed?: allowed?,
        enabled?: allowed? and not MapSet.member?(state.disabled_tools, Tool.name(tool))
      }
    end)
  end

  # Paired with the name, because `{:tools_disallowed, _}` is the only thing a
  # host or a person ever sees about a refusal and "not authorized" on its own
  # sends them looking at the wrong setting.
  def tool_denials(profile, tools) do
    for tool <- tools,
        {:deny, reason} <- [Profile.decision(profile, tool)],
        do: {Tool.name(tool), reason}
  end

  defp tool_source(%RemoteTool{server: server}), do: {:mcp, server}
  defp tool_source(%Descriptor{executor: %RemoteTool{server: server}}), do: {:mcp, server}
  defp tool_source(_tool), do: :local

  def enabled_tools(tools, disabled, profile) do
    profile
    |> Profile.filter(tools)
    |> Enum.reject(&MapSet.member?(disabled, Tool.name(&1)))
  end

  def update_disabled_tools(disabled, names, true),
    do: MapSet.difference(disabled, MapSet.new(names))

  def update_disabled_tools(disabled, names, false),
    do: MapSet.union(disabled, MapSet.new(names))

  def change_tool_access(state, _catalog, names, disabled_tools, enabled?)
      when disabled_tools == state.disabled_tools do
    action = if enabled?, do: :enabled, else: :disabled
    state = Core.emit(state, {:tool_access_changed, action, names, local_tool_names(state)})

    {:reply, {:ok, names}, state}
  end

  def change_tool_access(state, catalog, names, disabled_tools, enabled?) do
    tools = enabled_tools(catalog, disabled_tools, state.tool_profile)

    with :ok <- Tool.validate_all(tools),
         :ok <- Provider.validate_model(state.provider, state.model, tools) do
      action = if enabled?, do: :enabled, else: :disabled

      state =
        state
        |> Map.put(:disabled_tools, disabled_tools)
        |> Map.put(:tools, tools)
        |> Setup.record_config()
        |> Core.append(Setup.tool_profile_notice(state, tools))
        |> Core.emit({:tool_access_changed, action, names, local_tool_names(state)})

      {:reply, {:ok, names}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # A child's result envelope is the durable record of what it was billed, so the
  # parent's accounting only becomes true when one lands — before this, a
  # cancelled child's tokens were on the transcript and on nobody's screen. Only
  # `:subagent_result`: the `:subagent_group_result` that follows repeats the same
  # usage, and `Lemieux.Context.delegated_usages/1` says why folding both would
  # count a fan-out twice.
  def delegated_settled(state, :subagent_result),
    do: Core.emit(state, {:context, Compacting.context(state)})

  def delegated_settled(state, _type), do: state

  def change_model(state, model) do
    case Provider.validate_model(state.provider, model, state.tools) do
      :ok ->
        previous = state.model
        previous_effort = reasoning_effort(state)
        params = compatible_reasoning_params(state, model)

        state =
          state
          |> Map.put(:model, model)
          |> Map.put(:params, params)
          |> Map.put(:context_window, model_context_window(state, model))
          |> forget_served_window()
          |> Core.put_compaction(:compaction_failed?, false)
          |> Core.forget_compaction_failures()
          |> Setup.record_config()
          |> Core.emit({:model_changed, previous, model})

        state = maybe_emit_effort_change(state, previous_effort, reasoning_effort(state))

        state = Setup.notice_unknown_window(state)
        state = Core.emit(state, {:context, Compacting.context(state)})

        {:reply, {:ok, model}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # A refusal that states the window is the most authoritative statement of it a
  # session ever gets — for a model newer than the catalog, the only one. It
  # replaces what the provider said or the fallback stood in for, never what a
  # host configured, and a model change asks the provider again.
  def learn_window(%{context_window_source: :configured} = state, _reason), do: state

  def learn_window(state, reason) do
    case ProviderError.stated_context_window(reason) do
      window when is_integer(window) and window > 0 ->
        %{state | context_window: window, context_window_source: :stated}

      _unstated ->
        state
    end
  end

  defp model_context_window(%{context_window_source: :configured} = state, _model),
    do: state.context_window

  defp model_context_window(state, model), do: Provider.context_window(state.provider, model)

  # What a server reported serving belongs to the model it served, and the
  # new model's window was just asked of the provider.
  defp forget_served_window(%{context_window_source: :configured} = state),
    do: %{state | served_window: nil}

  defp forget_served_window(state),
    do: %{state | served_window: nil, context_window_source: :provider}

  def models(state) do
    requirements =
      if state.tools == [], do: [chat: true], else: [chat: true, tools: true]

    current =
      case Provider.validate_model(state.provider, state.model, state.tools) do
        :ok -> [state.model]
        {:error, _reason} -> []
      end

    discovered = Provider.available_models(state.provider, require: requirements)
    Enum.uniq(current ++ discovered)
  end

  def models_for(state, provider) do
    provider = provider |> String.trim() |> String.downcase()
    Enum.filter(models(state), &(ModelSpec.provider(&1) == provider))
  end

  def reasoning_effort(state), do: normalize_effort(Keyword.get(state.params, :reasoning_effort))

  def normalize_effort(nil), do: nil
  def normalize_effort(:default), do: nil
  def normalize_effort("default"), do: nil

  def normalize_effort(effort) when is_atom(effort),
    do: effort |> Atom.to_string() |> normalize_effort()

  def normalize_effort(effort) when is_binary(effort) do
    case effort |> String.trim() |> String.downcase() do
      "" -> nil
      "default" -> nil
      normalized -> normalized
    end
  end

  def put_reasoning_effort(params, nil), do: Keyword.delete(params, :reasoning_effort)

  def put_reasoning_effort(params, effort),
    do: Keyword.put(params, :reasoning_effort, effort)

  def change_reasoning_effort(state, effort) do
    previous = reasoning_effort(state)

    if previous == effort do
      {:reply, {:ok, effort || "default"}, state}
    else
      state =
        state
        |> Map.update!(:params, &put_reasoning_effort(&1, effort))
        |> Setup.record_config()
        |> Core.emit({:reasoning_effort_changed, previous || "default", effort || "default"})

      {:reply, {:ok, effort || "default"}, state}
    end
  end

  defp compatible_reasoning_params(state, model) do
    case reasoning_effort(state) do
      nil ->
        state.params

      effort ->
        if effort in Provider.reasoning_efforts(state.provider, model),
          do: state.params,
          else: put_reasoning_effort(state.params, nil)
    end
  end

  defp maybe_emit_effort_change(state, effort, effort), do: state

  defp maybe_emit_effort_change(state, previous, current),
    do: Core.emit(state, {:reasoning_effort_changed, previous || "default", current || "default"})
end
