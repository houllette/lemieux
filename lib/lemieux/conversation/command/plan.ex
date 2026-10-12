defmodule Lemieux.Conversation.Command.Plan do
  @moduledoc """
  `/plan [TOPIC | approve | edit TOPIC | export PATH | end]`.

  The person approves a concrete stored revision. Starting or editing a plan
  restricts tools before the prompt is submitted; ending planning does not
  approve it. Export is an explicit host file write, confined to the workspace.
  """
  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Environment
  alias Lemieux.Extensions.Planning
  alias Lemieux.Extensions.Workflow

  @impl true
  def spec,
    do: %{
      name: "plan",
      description: "inspect, draft, approve or export a plan",
      accepts_arguments?: true,
      action: {:plan, ""},
      actions: [{:plan, ""}]
    }

  @impl true
  def parse(_arguments, %{busy?: true}), do: Command.wait()
  def parse(arguments, _conversation), do: [{:plan, String.trim(arguments)}]

  @impl true
  def perform(acc, %Dispatch{session: nil} = host, _effect),
    do: Dispatch.say(acc, host, "no session is running")

  def perform(acc, host, {:plan, arguments}) do
    session = host.session
    context = %{cwd: Dispatch.cwd(host), environment: Dispatch.environment(host)}
    Dispatch.run(acc, host, fn -> action(session, context, arguments) end)
  end

  defp action(session, _cwd, "") do
    with {:ok, workflow} <- Workflow.read(session), {:ok, plan} <- Planning.read(session) do
      {:said, "plan: #{workflow.value["phase"]}\n" <> Planning.summary(plan)}
    else
      error -> failed(error)
    end
  end

  defp action(session, _cwd, "approve") do
    with {:ok, _workflow} <- Workflow.approve(session), {:ok, plan} <- Planning.read(session) do
      {:send_prompt,
       "Execute this human-approved plan under the current host permissions:\n" <>
         Planning.summary(plan), "approved plan revision #{plan.revision}"}
    else
      error -> failed(error)
    end
  end

  defp action(session, _cwd, "end") do
    case Workflow.enter(session, "idle") do
      {:ok, _document} -> {:said, "planning ended; no plan was approved"}
      error -> failed(error)
    end
  end

  defp action(session, %{cwd: cwd, environment: environment}, "export " <> path) do
    path = String.trim(path)

    with {:ok, plan} <- Planning.read(session),
         {:ok, _effect} <-
           Environment.write_file(
             environment,
             cwd,
             path,
             "# Plan\n\n" <> Planning.summary(plan) <> "\n"
           ) do
      {:said, "exported plan revision #{plan.revision} to #{path}"}
    else
      error -> failed(error)
    end
  end

  defp action(session, cwd, "edit " <> topic), do: action(session, cwd, topic)

  defp action(session, _cwd, topic) do
    case Workflow.enter(session, "planning", %{"topic" => topic}) do
      {:ok, _document} ->
        {:send_prompt,
         "Investigate and draft a concrete plan for: #{topic}. Record tasks with todo. Stop for human approval before executing.",
         "planning: #{topic}"}

      error ->
        failed(error)
    end
  end

  defp failed(error), do: {:said, "could not change plan: #{inspect(error)}"}
end
