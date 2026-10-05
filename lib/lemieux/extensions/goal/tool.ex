defmodule Lemieux.Extensions.Goal.Tool do
  @moduledoc false
  @behaviour Lemieux.Tool.Configured
  alias Lemieux.Extensions.Goal
  defstruct [:config, :action]
  @spec new(config :: struct(), action :: :get | :update) :: struct()
  def new(config, action), do: %__MODULE__{config: config, action: action}
  @impl true
  def name(%{action: :get}), do: "get_goal"
  def name(%{action: :update}), do: "update_goal"
  @impl true
  def description(%{action: :get}),
    do: "Read the host-authorized goal, revision and verification evidence."

  def description(%{action: :update}),
    do:
      "Request completion verification or report a blocker at the observed revision. This cannot create goals or extend budgets."

  @impl true
  def schema(%{action: :get}),
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  def schema(%{action: :update}),
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["revision", "status"],
      "properties" => %{
        "revision" => %{"type" => "integer", "minimum" => 0},
        "status" => %{"type" => "string", "enum" => ["complete", "blocked"]},
        "reason" => %{"type" => "string"}
      }
    }

  @impl true
  def run(%{action: :get}, _args, context), do: result(Goal.read(context.session))

  def run(
        %{action: :update, config: config},
        %{"status" => "complete", "revision" => revision},
        context
      )
      when is_integer(revision) and revision >= 0,
      do: result(Goal.verify(config, context.session, revision, context))

  def run(
        %{action: :update},
        %{"status" => "blocked", "revision" => revision, "reason" => reason},
        context
      )
      when is_integer(revision) and revision >= 0,
      do: result(Goal.block(context.session, revision, reason))

  def run(_tool, _args, _context),
    do: {:error, "provide an observed revision and a supported status"}

  defp result({:ok, document}), do: {:ok, Goal.summary(document)}
  defp result({:error, reason}), do: {:error, "goal unchanged: #{inspect(reason)}"}
end
