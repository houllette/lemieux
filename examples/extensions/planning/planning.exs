defmodule LemieuxPlanningExample do
  @moduledoc """
  A one-file script extension that adds one deterministic tool, `plan_order`.

  `lmx` already keeps a session plan with its `todo` tool. What goes wrong is
  less often writing the steps down than ordering them: starting a step before
  the one it depends on, or not noticing that two steps wait on each other.
  `plan_order` answers that mechanically, so the answer is the same every time
  and never depends on the model.

  `apply/2` only appends the tool. An earlier version of this example
  re-applied `Lemieux.Extensions.Planning`, which `lmx` already applies, and
  every session it was loaded into stopped before its first request with
  `{:duplicate_tool_name, "todo"}`: two tools may not share a name. An
  extension adds what is not there yet.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  @impl true
  @spec apply(harness :: Lemieux.Harness.t(), opts :: term()) :: Lemieux.Harness.t()
  def apply(harness, _opts),
    do: Lemieux.Harness.update_tools(harness, &(&1 ++ [LemieuxPlanningExample.PlanOrder]))

  @impl true
  @spec describe(opts :: term()) :: map()
  def describe(_opts), do: %{"tool" => "plan_order", "revision" => 1}
end

defmodule LemieuxPlanningExample.PlanOrder do
  @moduledoc """
  Orders plan steps so that each comes after the steps it depends on.

  Pure: no files, no network, no model. Among steps that are free to go next,
  the one listed first goes first, so the same input always gives the same
  order. A dependency cycle or a dependency on a step that does not exist is
  reported as an error the model reads, never resolved by guessing.
  """

  @behaviour Lemieux.Tool

  @max_steps 100

  @impl true
  @spec name() :: String.t()
  def name, do: "plan_order"

  @impl true
  @spec description() :: String.t()
  def description do
    "Order plan steps so that every step comes after the steps it depends on. " <>
      "Deterministic: steps free to go next keep the order given. Reports a dependency " <>
      "cycle or an unknown dependency instead of guessing. Use it before recording a " <>
      "multi-step plan whose steps depend on each other."
  end

  @impl true
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "steps" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_steps,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string", "description" => "A short, unique name for the step."},
              "after" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Ids of the steps that must be finished before this one."
              }
            },
            "required" => ["id"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["steps"],
      "additionalProperties" => false
    }
  end

  @impl true
  @spec run(args :: map(), context :: Lemieux.Tool.context()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(%{"steps" => [_ | _] = steps}, _context) when length(steps) <= @max_steps do
    with {:ok, graph} <- graph(steps, [], MapSet.new()),
         :ok <- known(graph),
         {:ok, order} <- order(graph, [], MapSet.new()) do
      {:ok, order |> Enum.with_index(1) |> Enum.map_join("\n", fn {id, n} -> "#{n}. #{id}" end)}
    end
  end

  def run(_args, _context),
    do: {:error, "steps must be a list of 1 to #{@max_steps} objects, each with an id"}

  @impl true
  @spec read_only?() :: boolean()
  def read_only?, do: true

  @impl true
  @spec parallel_safe?() :: boolean()
  def parallel_safe?, do: true

  # `graph` is `[{id, after}]` in the order given.
  defp graph([], graph, _seen), do: {:ok, Enum.reverse(graph)}

  defp graph([%{"id" => id} = step | rest], graph, seen) when is_binary(id) and id != "" do
    after_ids = Map.get(step, "after", [])

    cond do
      MapSet.member?(seen, id) ->
        {:error, "step #{inspect(id)} appears twice; give every step its own id"}

      not (is_list(after_ids) and Enum.all?(after_ids, &is_binary/1)) ->
        {:error, "step #{inspect(id)}: after must be a list of step ids"}

      true ->
        graph(rest, [{id, Enum.uniq(after_ids)} | graph], MapSet.put(seen, id))
    end
  end

  defp graph([_step | _rest], _graph, _seen),
    do: {:error, "every step needs a non-empty string id"}

  defp known(graph) do
    ids = MapSet.new(graph, &elem(&1, 0))

    Enum.find_value(graph, :ok, fn {id, after_ids} ->
      case Enum.reject(after_ids, &MapSet.member?(ids, &1)) do
        [] ->
          nil

        [missing | _] ->
          {:error, "step #{inspect(id)} is after #{inspect(missing)}, which is not a step"}
      end
    end)
  end

  # Takes the first step whose dependencies are all placed, until none is
  # left. When steps remain and none can go, every one of them waits, directly
  # or through another, on a cycle.
  defp order([], placed, _done), do: {:ok, Enum.reverse(placed)}

  defp order(pending, placed, done) do
    case Enum.find(pending, fn {_id, after_ids} ->
           Enum.all?(after_ids, &MapSet.member?(done, &1))
         end) do
      {id, _after_ids} = step ->
        order(List.delete(pending, step), [id | placed], MapSet.put(done, id))

      nil ->
        blocked = Enum.map_join(pending, ", ", &elem(&1, 0))
        {:error, "no order exists: a dependency cycle blocks #{blocked}"}
    end
  end
end
