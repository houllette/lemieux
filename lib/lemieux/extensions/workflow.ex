defmodule Lemieux.Extensions.Workflow do
  @moduledoc """
  Durable planning and review authority, layered over host permissions.

  Planning and review admit only descriptor-certified reads, questions and
  the session's own plan tool. A remembered shell rule or an earlier hook's
  allow cannot turn these workflows into writers. Only host commands change
  phase; models have no approval tool. Approval names the plan revision and
  obligations digest. Progress updates remain valid; changing obligations
  requires a fresh human decision. The document survives
  resume and fork; it only restricts current host authority, never expands it.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Extensions.Planning
  alias Lemieux.Extensions.Planning.Reducer
  alias Lemieux.Extensions.Workflow.ReviewResult
  alias Lemieux.Harness
  alias Lemieux.Session
  alias Lemieux.Tool

  @namespace "lemieux.workflow"

  @impl true
  def apply(harness, _opts) do
    Harness.append_hooks(harness,
      prepare_next_turn: &prepare/2,
      before_tool_call: &__MODULE__.check/2,
      stop: &stop/2
    )
  end

  @doc "Reads the durable workflow state."
  @spec read(session :: Session.session()) :: {:ok, map()} | {:error, term()}
  def read(session) do
    with {:ok, document} <- Session.document(session, @namespace) do
      value = document.value || %{"phase" => "idle"}
      if valid?(value), do: {:ok, %{document | value: value}}, else: {:error, :invalid_workflow}
    end
  end

  @doc "Enters a restrictive workflow or leaves it by an explicit host decision."
  @spec enter(session :: Session.session(), phase :: String.t(), details :: map()) ::
          {:ok, map()} | {:error, term()}
  def enter(session, phase, details \\ %{}) when phase in ~w(planning review idle) do
    with :ok <- installed(session), :ok <- idle(session), {:ok, document} <- read(session) do
      Session.put_document(
        session,
        @namespace,
        document.revision,
        Map.merge(details, %{"phase" => phase})
      )
    end
  end

  @doc "Approves the current nonempty plan revision without relaxing host policy."
  @spec approve(session :: Session.session()) :: {:ok, map()} | {:error, term()}
  def approve(session) do
    with :ok <- installed(session),
         :ok <- idle(session),
         {:ok, document} <- read(session),
         true <- document.value["phase"] == "planning",
         {:ok, plan} <- Planning.read(session),
         true <- Planning.tasks(plan.value) != [] do
      Session.put_document(session, @namespace, document.revision, %{
        "phase" => "approved",
        "plan_revision" => plan.revision,
        "plan_digest" => plan_digest(plan.value)
      })
    else
      false -> {:error, :no_plan_to_approve}
      error -> error
    end
  end

  @doc false
  @spec prepare(request :: Lemieux.Request.t(), context :: map()) :: term()
  def prepare(request, context) do
    case read(context.session) do
      {:ok, %{value: workflow}} -> prepare_phase(request, context.session, workflow)
      error -> {:deny, "Cannot reconstruct workflow: #{inspect(error)}"}
    end
  end

  defp prepare_phase(request, _session, %{"phase" => phase}) when phase in ~w(planning review) do
    instruction =
      if phase == "planning",
        do:
          "Plan only. Investigate with read-only tools, record concrete tasks with todo, and wait for the person to approve the plan before executing it.",
        else:
          "Review only. Read the selected changes. Do not edit files or run commands. Distinguish observed facts from untested concerns. Your final answer must be JSON conforming to this findings schema, without Markdown fences:\n" <>
            JSON.encode!(ReviewResult.schema())

    {:ok,
     %{
       request
       | tools: Enum.filter(request.tools, &permitted?/1),
         system: Enum.join([request.system || "", instruction], "\n\n")
     }}
  end

  defp prepare_phase(request, session, %{"phase" => "approved", "plan_digest" => digest}) do
    case Planning.read(session) do
      {:ok, %{value: plan}} ->
        if plan_digest(plan) == digest,
          do: {:ok, request},
          else:
            {:deny,
             "The approved plan changed. Use /plan edit, then /plan approve to authorize its new obligations."}

      _changed ->
        {:deny, "The approved plan changed. Use /plan approve to authorize its current revision."}
    end
  end

  defp prepare_phase(request, _session, _workflow), do: {:ok, request}

  @doc false
  @spec check(call :: map(), context :: map()) :: Lemieux.Hooks.answer()
  def check(call, context) do
    case read(context.session) do
      {:ok, %{value: %{"phase" => phase}}} when phase in ~w(planning review) ->
        descriptor = Map.get(context, :tool_descriptor, %{})

        if get_in(descriptor, ["effects", "class"]) == "read" or call.name in ~w(todo ask_user),
          do: :allow,
          else:
            {:deny,
             "#{phase} permits only certified reads and session planning; no write or shell authority"}

      {:ok, %{value: %{"phase" => "approved", "plan_digest" => digest}}} ->
        approved_call(call, context.session, digest)

      {:ok, _document} ->
        :allow

      {:error, _reason} ->
        {:deny, "Cannot reconstruct workflow authority"}
    end
  end

  defp approved_call(%{name: "todo", arguments: %{"action" => "list"}}, _session, _digest),
    do: :allow

  defp approved_call(%{name: "todo", arguments: command}, session, digest) do
    with {:ok, %{value: plan}} <- Planning.read(session),
         {:ok, next} <- Reducer.apply(plan, command),
         true <- plan_digest(next) == digest do
      :allow
    else
      _changed ->
        {:deny,
         "Approval covers the recorded obligations; use /plan edit and approve before changing them. Progress updates remain allowed."}
    end
  end

  defp approved_call(_call, session, digest) do
    case Planning.read(session) do
      {:ok, %{value: plan}} ->
        if plan_digest(plan) == digest,
          do: :allow,
          else: {:deny, "The approved obligations changed; a new human decision is required."}

      _invalid ->
        {:deny, "Cannot reconstruct approved obligations"}
    end
  end

  defp valid?(%{"phase" => "approved", "plan_revision" => revision, "plan_digest" => digest}),
    do: is_integer(revision) and revision > 0 and is_binary(digest) and byte_size(digest) == 64

  defp valid?(%{"phase" => phase}), do: phase in ~w(idle planning review)
  defp valid?(_value), do: false

  defp permitted?(tool), do: Tool.read_only?(tool) or Tool.name(tool) in ~w(todo ask_user)

  @doc false
  @spec stop(reason :: atom(), context :: map()) :: :allow
  def stop(:stop, %{session: session, aside: nil}) do
    case read(session) do
      {:ok, %{value: %{"phase" => "review"} = workflow}} -> ReviewResult.record(session, workflow)
      _other -> :ok
    end

    :allow
  end

  def stop(_reason, _context), do: :allow

  defp plan_digest(plan) do
    plan["tasks"]
    |> Enum.reject(&(&1["status"] == "deleted"))
    |> Enum.map(&Map.take(&1, ~w(id title depends_on owner)))
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp idle(session) do
    if Session.info(session).status == :idle, do: :ok, else: {:error, :busy}
  end

  defp installed(session) do
    hooks = Session.delegation_context(session).hooks

    if Enum.any?(hooks, fn
         {:before_tool_call, fun} -> fun == (&__MODULE__.check/2)
         _hook -> false
       end), do: :ok, else: {:error, :workflow_not_applied}
  end
end
