# What the menus offer and what the session will accept from this screen: the
# model catalog, tool statuses, the command policy, and the Elixir tool mode.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Choices do
    @moduledoc "Keeps a `Lemieux.TUI`'s menus and command policy in step with its session."

    alias Lemieux.Conversation
    alias Lemieux.ModelSpec
    alias Lemieux.Session
    alias Lemieux.Tools
    alias Lemieux.TUI
    alias Lemieux.TUI.CatalogState
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.Editor
    alias Lemieux.TUI.Transcript

    # `/elixir` swaps the catalog for a tool the host profile may refuse, and a
    # command that can only fail should not be in the menu offering it. The command
    # list, `/help` and `Lemieux.TUI.Effects` all consult this one function, so
    # hiding it and explaining it cannot disagree.
    @doc false
    @spec command_policy(TUI.t()) :: Conversation.command_policy()
    def command_policy(state) do
      host = state.tool_choices.command_policy

      case state.tool_choices.elixir do
        :allow ->
          host

        {:deny, reason} ->
          message = "the elixir tool is not available here: #{Conversation.denial(reason)}"

          fn
            :toggle_elixir_mode -> {:deny, message}
            action -> Conversation.command_decision(host, action)
          end
      end
    end

    @doc false
    @spec tool_statuses(TUI.t()) :: [Session.tool_status()]
    def tool_statuses(state), do: state.tool_choices.statuses

    @doc false
    @spec put_tool_statuses(TUI.t(), [Session.tool_status()]) :: TUI.t()
    def put_tool_statuses(state, statuses),
      do: put_in(state.tool_choices.statuses, statuses)

    # `/mcp remove` and `/mcp reconnect` take a configured server's name, and
    # nobody types one from memory. Kept in the catalog with the other menu
    # sources rather than asked for while drawing: completions run on every
    # keystroke, and `Session.mcp_status/1` is a call.
    @doc false
    @spec put_mcp_names(TUI.t(), list()) :: TUI.t()
    def put_mcp_names(state, statuses),
      do: put_in(state.catalog.mcp, CatalogState.server_names(statuses))

    @doc false
    @spec refresh_choices(TUI.t()) :: TUI.t()
    def refresh_choices(%TUI{session: nil} = state), do: state

    def refresh_choices(state),
      do: refresh_choices(state, ModelSpec.provider(state.conversation.model))

    @doc false
    @spec refresh_choices(TUI.t(), String.t() | nil) :: TUI.t()
    def refresh_choices(state, provider) do
      state =
        state
        |> put_in([Access.key!(:catalog), :efforts], Session.reasoning_efforts(state.session))
        |> put_in([Access.key!(:catalog), :model_metadata], Session.model_metadata(state.session))

      merge_discovered_choices(
        state,
        provider,
        Session.available_providers(state.session),
        models_for(state.session, provider)
      )
    end

    @doc false
    @spec models_for(pid(), String.t() | nil) :: [String.t()]
    def models_for(session, provider) when is_binary(provider),
      do: Session.available_models(session, provider)

    def models_for(session, nil), do: Session.available_models(session)

    # A provider switch uses a preferred or recent model when one is available,
    # then puts the refreshed choices directly in front of the person. Changing
    # provider and inspecting its models stays one continuous completion flow.
    @doc false
    @spec open_model_completions(TUI.t(), String.t() | nil) :: TUI.t()
    def open_model_completions(state, provider) do
      state = %{refresh_choices(state, provider) | model_tab: "Automatic"}
      :ok = Editor.replace(state.input, "/model ")

      Composer.edited(state)
    end

    # The model ends the flow: the levels belong to it, so a switch both changes
    # which are offered and resets which is current, and opening the menu is the only
    # thing that says either. A model with no levels ends with an empty box rather
    # than a command whose menu is empty, which reads as a broken one. Reached from
    # `/model` typed directly as well as from `/provider`, so the flow is one however
    # far into it somebody started.
    @doc false
    @spec open_effort_completions(TUI.t()) :: TUI.t()
    def open_effort_completions(%TUI{catalog: %{efforts: []}} = state), do: state

    def open_effort_completions(state) do
      :ok = Editor.replace(state.input, "/effort ")

      Composer.edited(state)
    end

    # A host's model discovery arriving late — an Ollama list, say — merged
    # into what the menus offer for the current provider. Specs, and the
    # host's `{:preferred, spec}`, which `CatalogState.discover/3` puts first.
    @doc false
    @spec discovered(TUI.t(), [CatalogState.discovery()]) :: TUI.t()
    def discovered(state, models) do
      provider = ModelSpec.provider(state.conversation.model)
      catalog = CatalogState.discover(state.catalog, models, provider)
      %{state | catalog: catalog}
    end

    @doc false
    @spec remember_model(TUI.t(), String.t()) :: TUI.t()
    def remember_model(state, model) do
      %{state | catalog: CatalogState.remember(state.catalog, model)}
    end

    @doc false
    @spec selection_preferences(TUI.t()) :: map()
    def selection_preferences(state), do: CatalogState.selection_preferences(state.catalog)

    @doc false
    @spec elixir_mode(TUI.t(), [String.t()]) :: TUI.t()
    def elixir_mode(state, names), do: %{state | elixir_mode?: elixir_mode?(names)}

    @doc false
    @spec toggle_elixir_mode(TUI.t()) :: TUI.t()
    def toggle_elixir_mode(state) do
      # Read back before the swap, every time. The host built the delegate tool
      # (`Lemieux.CLI.Runtime.configure_delegation/4`) and handed it to the
      # session in `:tools`; the list this function passes must carry it on,
      # and a swap that omitted it would leave the session unable to delegate
      # for the rest of its life.
      state = remember_delegation(state)

      tools =
        if state.elixir_mode?,
          do: standard_tools(state),
          else: [Tools.Eval, Tools.AskUser] ++ List.wrap(state.tool_choices.delegation)

      case Session.set_tools(state.session, tools) do
        {:ok, names} ->
          elixir_mode(state, names)

        {:error, reason} ->
          Transcript.say(
            state,
            :lmx,
            "could not switch tool mode: #{Conversation.describe(reason)}"
          )
      end
    end

    defp merge_discovered_choices(state, provider, providers, models) do
      %{state | catalog: CatalogState.merge(state.catalog, provider, providers, models)}
    end

    # What `/elixir` off goes back to. The `delegate` tool is a struct the host
    # built and handed to the session in `:tools`; `:delegation` is the one the
    # session held when the mode went on, read back so the mode can restore it.
    # Without it, toggling the mode left the session unable to delegate for the
    # rest of its life.
    defp standard_tools(state),
      do: state.tool_choices.standard ++ List.wrap(state.tool_choices.delegation)

    defp remember_delegation(%TUI{session: nil} = state), do: state

    defp remember_delegation(state) do
      delegate =
        state.session |> Session.tools() |> Enum.find(&(Lemieux.Tool.name(&1) == "delegate"))

      put_in(state.tool_choices.delegation, delegate)
    end

    defp elixir_mode?(names) when is_list(names), do: Conversation.elixir_mode?(names)
  end
end
