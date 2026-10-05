# The MCP modal owns its keyboard flow and asynchronous server changes.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.MCPInteraction do
    @moduledoc "Handles the MCP manager and add-server form for a TUI state."

    alias Lemieux.Conversation
    alias Lemieux.Extensions.Workspace.Discovery
    alias Lemieux.MCP.Config, as: MCPConfig
    alias Lemieux.Session
    alias Lemieux.TUI.Choices
    alias Lemieux.TUI.Editor
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.MCPForm
    alias Lemieux.TUI.QuestionFlow

    @doc false
    @spec key(ExRatatui.Event.Key.t(), map(), map()) :: tuple()
    def key(
          %ExRatatui.Event.Key{code: "esc"},
          %{tools: %{mcp_flow: %{busy?: true}}} = state,
          _ctx
        ),
        do: {:noreply, state}

    def key(_event, %{tools: %{mcp_flow: %{busy?: true}}} = state, _ctx),
      do: {:noreply, state}

    def key(event, %{tools: %{mcp_flow: %{mode: :add}}} = state, ctx),
      do: mcp_add_key(event, state, ctx)

    def key(%ExRatatui.Event.Key{code: "esc"}, state, ctx),
      do: ctx.continue.(put_in(state.tools.mcp_flow, nil))

    def key(%ExRatatui.Event.Key{code: code}, state, _ctx) when code in ["up", "down", "tab"] do
      flow = state.tools.mcp_flow
      count = length(flow.statuses)
      by = if(code == "up", do: -1, else: 1)
      selected = if(count == 0, do: 0, else: Integer.mod(flow.selected + by, count))

      updated =
        flow
        |> Map.put(:selected, selected)
        |> Map.put(:confirm_remove, nil)
        |> Map.put(:confirm_delete, nil)

      {:noreply, put_in(state.tools.mcp_flow, updated)}
    end

    def key(%ExRatatui.Event.Key{code: "a"}, state, _ctx) do
      :ok = Editor.replace(state.input, "")

      flow =
        state.tools.mcp_flow
        |> Map.merge(%{
          mode: :add,
          questionnaire: MCPForm.new(),
          notice: nil,
          path: mcp_config_path(state)
        })

      {:noreply, put_in(state.tools.mcp_flow, flow)}
    end

    def key(%ExRatatui.Event.Key{code: "D"}, state, ctx), do: mcp_delete_key(state, ctx)

    def key(%ExRatatui.Event.Key{code: "d", modifiers: ["shift"]}, state, ctx),
      do: mcp_delete_key(state, ctx)

    def key(%ExRatatui.Event.Key{code: "d"}, state, ctx) do
      case Enum.at(state.tools.mcp_flow.statuses, state.tools.mcp_flow.selected) do
        nil ->
          {:noreply, state}

        %{name: name} when state.tools.mcp_flow.confirm_remove == name ->
          mcp_change(
            state,
            {:mcp_remove, name},
            fn ->
              Session.remove_mcp_server(state.session, name)
            end,
            ctx
          )

        server ->
          flow =
            state.tools.mcp_flow
            |> Map.put(:confirm_remove, server.name)
            |> Map.put(:confirm_delete, nil)
            |> Map.put(:notice, "Press d again to remove #{server.name} from this session.")

          {:noreply, put_in(state.tools.mcp_flow, flow)}
      end
    end

    def key(%ExRatatui.Event.Key{code: "r"}, state, ctx) do
      case Enum.at(state.tools.mcp_flow.statuses, state.tools.mcp_flow.selected) do
        nil ->
          {:noreply, state}

        server ->
          mcp_change(
            state,
            {:mcp_reconnect, server.name},
            fn ->
              Session.reconnect_mcp(state.session, server.name)
            end,
            ctx
          )
      end
    end

    def key(%ExRatatui.Event.Key{code: "o"}, state, ctx) do
      case Enum.at(state.tools.mcp_flow.statuses, state.tools.mcp_flow.selected) do
        nil ->
          {:noreply, state}

        server ->
          enabled? = Map.get(server, :enabled?, true)

          mcp_change(
            state,
            {:mcp_toggle, server.name, not enabled?},
            fn ->
              Session.set_mcp_enabled(state.session, server.name, not enabled?)
            end,
            ctx
          )
      end
    end

    def key(event, state, ctx) do
      if Keys.action(state.status.keys, event) == :interrupt,
        do: ctx.interrupt.(state),
        else: {:noreply, state}
    end

    defp mcp_delete_key(state, ctx) do
      case Enum.at(state.tools.mcp_flow.statuses, state.tools.mcp_flow.selected) do
        nil ->
          {:noreply, state}

        %{name: name} when state.tools.mcp_flow.confirm_delete == name ->
          path = mcp_config_path(state)

          mcp_change(
            state,
            {:mcp_delete, path, name},
            fn ->
              mcp_delete(state.session, path, name)
            end,
            ctx
          )

        server ->
          path = mcp_config_path(state)

          flow =
            state.tools.mcp_flow
            |> Map.put(:confirm_delete, server.name)
            |> Map.put(:confirm_remove, nil)
            |> Map.put(:notice, "Press Shift+D again to delete #{server.name} from #{path}.")

          {:noreply, put_in(state.tools.mcp_flow, flow)}
      end
    end

    defp mcp_add_key(%ExRatatui.Event.Key{code: "esc"}, state, _ctx) do
      :ok = Editor.replace(state.input, "")
      {:noreply, put_in(state.tools.mcp_flow.mode, :list)}
    end

    defp mcp_add_key(%ExRatatui.Event.Key{code: code, modifiers: modifiers}, state, _ctx)
         when code in ["left", "right", "tab", "back_tab"] do
      by = if code in ["left", "back_tab"] or "shift" in modifiers, do: -1, else: 1

      questionnaire =
        state.tools.mcp_flow.questionnaire
        |> QuestionFlow.stash_editor(ExRatatui.textarea_get_value(state.input))
        |> QuestionFlow.tab(by)

      {:noreply, mcp_add_update(state, questionnaire)}
    end

    defp mcp_add_key(%ExRatatui.Event.Key{code: code}, state, _ctx)
         when code in ["up", "down"] do
      questionnaire = state.tools.mcp_flow.questionnaire

      if questionnaire.review? or QuestionFlow.current(questionnaire).type == "single_choice" do
        by = if code == "up", do: -1, else: 1
        {:noreply, mcp_add_update(state, QuestionFlow.move(questionnaire, by))}
      else
        {:noreply, state}
      end
    end

    defp mcp_add_key(
           %ExRatatui.Event.Key{code: "enter", modifiers: modifiers} = event,
           state,
           ctx
         ) do
      questionnaire = state.tools.mcp_flow.questionnaire

      cond do
        "shift" in modifiers ->
          ctx.edit.(event, state)

        questionnaire.review? ->
          case QuestionFlow.choose(questionnaire) do
            {:submit, complete} -> mcp_save(state, complete, ctx)
            {_status, next} -> {:noreply, mcp_add_update(state, next)}
          end

        QuestionFlow.current(questionnaire).type == "single_choice" ->
          # Only the transport choice changes which questions follow; the save
          # scope is answered like any other.
          transport? = QuestionFlow.current(questionnaire).id == "transport"

          case QuestionFlow.choose(questionnaire) do
            {:staged, next} when transport? ->
              {:noreply, mcp_add_update(state, MCPForm.expand_transport(next))}

            {_status, next} ->
              {:noreply, mcp_add_update(state, next)}
          end

        true ->
          mcp_add_text(state, questionnaire)
      end
    end

    defp mcp_add_key(
           event,
           %{tools: %{mcp_flow: %{questionnaire: %{other?: true}}}} = state,
           ctx
         ),
         do: ctx.edit.(event, state)

    defp mcp_add_key(_event, state, _ctx), do: {:noreply, state}

    defp mcp_add_text(state, questionnaire) do
      question = QuestionFlow.current(questionnaire)

      case MCPForm.text_answer(question.id, ExRatatui.textarea_get_value(state.input)) do
        {:ok, value} ->
          {:staged, next} = QuestionFlow.custom(questionnaire, value)
          {:noreply, mcp_add_update(state, next)}

        {:error, reason} ->
          {:noreply, put_in(state.tools.mcp_flow.questionnaire.notice, reason)}
      end
    end

    defp mcp_add_update(state, questionnaire) do
      value =
        if questionnaire.review? or not questionnaire.other?,
          do: "",
          else: QuestionFlow.other_text(questionnaire)

      :ok = Editor.replace(state.input, value)
      put_in(state.tools.mcp_flow.questionnaire, Map.put(questionnaire, :notice, nil))
    end

    # The reviewed server goes where the person chose — their own settings
    # by default — with any secret it carried replaced by a `${NAME}`
    # reference. The withheld values go into this process's environment, so
    # the server connects now; the result notice names the variables to
    # export before the next start. See `Lemieux.TUI.MCPForm.withheld/1`.
    defp mcp_save(state, questionnaire, ctx) do
      {server, secrets} = questionnaire |> MCPForm.server() |> MCPForm.withheld()
      {path, save} = destination(state, MCPForm.scope(questionnaire))
      Enum.each(secrets, fn {name, value} -> System.put_env(name, value) end)

      state =
        put_in(
          state.tools.mcp_flow,
          Map.put(state.tools.mcp_flow, :withheld, Enum.map(secrets, &elem(&1, 0)))
        )

      mcp_change(
        state,
        {:mcp_add, path, server["name"]},
        fn ->
          with :ok <- save.(server) do
            Session.add_mcp_servers(state.session, [server])
          end
        end,
        ctx
      )
    end

    # The personal settings file is the host's to write
    # (`Lemieux.CLI.Config.put_mcp_server/2`, called by name so this screen
    # does not need the CLI to compile). A host without it, or without a
    # settings file, saves to the repository as before.
    defp destination(state, "personal") do
      config = Module.concat([Lemieux, CLI, Config])
      path = Map.get(state.references, :config_path)

      if is_binary(path) and Code.ensure_loaded?(config) and
           function_exported?(config, :put_mcp_server, 2),
         do: {path, fn server -> config.put_mcp_server(path, server) end},
         else: destination(state, "project")
    end

    defp destination(state, "project") do
      path = state.tools.mcp_flow.path
      {path, fn server -> MCPConfig.put_server(path, server) end}
    end

    defp mcp_config_path(state) do
      cwd = state.references.cwd || File.cwd!()

      state.references.mcp_config || Discovery.project_mcp_config(cwd) ||
        Path.join(cwd, ".mcp.json")
    end

    defp mcp_delete(session, path, name) do
      with {:ok, servers} <- MCPConfig.read(path),
           %{} = server <- Enum.find(servers, &(&1["name"] == name)),
           :ok <- Session.remove_mcp_server(session, name) do
        case MCPConfig.delete_server(path, name) do
          :ok ->
            :ok

          {:error, reason} ->
            Session.add_mcp_servers(session, [server])
            {:error, reason}
        end
      else
        nil -> {:error, "#{name} is not present in #{path}"}
        {:error, reason} -> {:error, reason}
      end
    end

    defp mcp_change(state, action, work, ctx) do
      policy_action =
        case action do
          {:mcp_toggle, name, _enabled?} -> {:mcp_reconnect, name}
          {:mcp_add, path, _name} -> {:mcp_add, path}
          {:mcp_delete, _path, name} -> {:mcp_remove, name}
          other -> other
        end

      case Conversation.command_decision(ctx.policy, policy_action) do
        :allow ->
          app = self()
          session = state.session

          Task.start(fn ->
            result = work.()
            send(app, {:mcp_ui_result, action, result, Session.mcp_status(session)})
          end)

          flow =
            state.tools.mcp_flow
            |> Map.merge(%{
              busy?: true,
              notice: "Working…",
              confirm_remove: nil,
              confirm_delete: nil
            })

          {:noreply, put_in(state.tools.mcp_flow, flow)}

        {:deny, reason} ->
          {:noreply, put_in(state.tools.mcp_flow.notice, reason)}
      end
    end

    # A change the manager sent off finished. The menus and the tool statuses
    # are refreshed whether or not the manager is still open; the manager, if
    # it is, goes back to its list with the outcome as its notice.
    @doc false
    @spec ui_result(map(), term(), term(), list()) :: {:noreply, map()}
    def ui_result(state, action, result, statuses) do
      state =
        state
        |> Choices.put_mcp_names(statuses)
        |> Choices.put_tool_statuses(Session.tool_status(state.session))

      flow = state.tools.mcp_flow

      if is_nil(flow) do
        {:noreply, state}
      else
        selected = min(flow.selected, max(length(statuses) - 1, 0))
        notice = result_notice(action, result, statuses) <> exports(Map.get(flow, :withheld, []))

        updated = %{
          flow
          | statuses: statuses,
            selected: selected,
            mode: :list,
            busy?: false,
            confirm_remove: nil,
            confirm_delete: nil,
            notice: notice
        }

        updated = Map.delete(updated, :withheld)
        :ok = Editor.replace(state.input, "")
        {:noreply, put_in(state.tools.mcp_flow, updated)}
      end
    end

    defp exports([]), do: ""

    defp exports(names),
      do:
        " Secrets were saved as references; export #{Enum.join(names, ", ")} before the next start."

    @doc false
    @spec result_notice(term(), term(), list()) :: String.t()
    def result_notice(_action, {:error, :server_disabled}, _statuses),
      do: "This server is off for this session. Press o to turn it on."

    def result_notice(_action, {:error, reason}, _statuses),
      do: "MCP: #{Conversation.describe(reason)}"

    def result_notice({:mcp_remove, name}, :ok, _statuses),
      do: "#{name} removed from this session."

    def result_notice({:mcp_delete, path, name}, :ok, _statuses),
      do: "#{name} deleted from #{path} and this session."

    def result_notice({:mcp_toggle, name, true}, :ok, _statuses),
      do: "#{name} is on for this session."

    def result_notice({:mcp_toggle, name, false}, :ok, _statuses),
      do: "#{name} is off for this session."

    def result_notice({:mcp_reconnect, name}, :ok, statuses) do
      case Enum.find(statuses, &(&1.name == name)) do
        %{error: error} when is_binary(error) -> "#{name}: #{error}"
        %{tool_count: 0} -> "#{name} connected, but no tools are available."
        %{enabled?: false} -> "#{name} is off for this session."
        %{tool_count: count} -> "#{name} connected with #{count} tools."
        _other -> "MCP status refreshed."
      end
    end

    def result_notice({:mcp_add, path, name}, :ok, statuses) do
      case Enum.find(statuses, &(&1.name == name)) do
        %{error: error} when is_binary(error) ->
          "Saved to #{path}; connection failed: #{error}"

        %{tool_count: 0} ->
          "Saved to #{path}; no tools are available."

        %{name: name, tool_count: count} ->
          "Saved #{name} to #{path}; #{count} tools available."

        _other ->
          "Server saved."
      end
    end

    def result_notice(_action, :ok, _statuses), do: "MCP status updated."
  end
end
