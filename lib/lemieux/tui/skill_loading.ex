if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.SkillLoading do
    @moduledoc false

    alias Lemieux.Conversation
    alias Lemieux.Extensions.Workspace.Skill
    alias Lemieux.Session
    alias Lemieux.TUI
    alias Lemieux.TUI.Effects
    alias Lemieux.TUI.Transcript

    # A reader can perform remote I/O. Keep it off the render loop, and bind
    # its answer to this session and task so a late load cannot prompt a new
    # session. The environment comes from the session, as tool contexts do.
    @spec start(state :: TUI.t(), skill :: Skill.t(), arguments :: String.t()) :: TUI.t()
    def start(state, skill, arguments) do
      session = state.session

      work = fn ->
        context = Session.delegation_context(session)
        {context.environment, Skill.render(skill, arguments, environment: context.environment)}
      end

      task =
        case state.resume.task_supervisor do
          nil -> Task.async(work)
          supervisor -> Task.Supervisor.async_nolink(supervisor, work)
        end

      put_in(state.references[:skill_load], %{task: task, session: session})
    end

    @spec answer(state :: TUI.t(), result :: term()) :: TUI.t()
    def answer(state, {environment, result}) do
      %{task: task, session: session} = state.references.skill_load
      Process.demonitor(task.ref, [:flush])
      state = put_in(state.references.skill_load, nil)

      if state.session == session and not state.resume.busy? and
           not state.conversation.busy? and
           state.references.environment in [nil, environment] do
        loaded(state, result)
      else
        state
      end
    end

    @spec failed(state :: TUI.t()) :: TUI.t()
    def failed(state),
      do:
        state
        |> put_in([Access.key!(:references), :skill_load], nil)
        |> loaded({:error, "reader stopped"})

    @spec cancel(state :: TUI.t()) :: TUI.t()
    def cancel(%TUI{references: %{skill_load: %{task: task}}} = state) do
      Task.shutdown(task, :brutal_kill)
      put_in(state.references.skill_load, nil)
    end

    def cancel(state), do: state

    defp loaded(state, {:ok, rendered}) do
      {conversation, effects} = Conversation.input(state.conversation, rendered)
      {:noreply, state} = Effects.run(%{state | conversation: conversation}, effects)
      state
    end

    defp loaded(state, {:error, reason}),
      do: Transcript.say(state, :lmx, "could not load skill: #{reason}")
  end
end
