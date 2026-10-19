defmodule Lemieux.Extensions.Watches.Tool do
  @moduledoc "The optional configured watch tool; continuation authority is supplied by the host."
  @behaviour Lemieux.Tool.Configured
  alias Lemieux.Extensions.Watches
  alias Lemieux.Tool.Result

  defstruct [:manager, :sources, allow_follow_up: false]

  @doc "The manager may be a server reference or a context-to-server resolver."
  @spec new(opts :: keyword()) :: struct()
  def new(opts),
    do: struct!(__MODULE__, Keyword.take(opts, [:manager, :sources, :allow_follow_up]))

  @impl true
  def name(_tool), do: "watch"
  @impl true
  def description(_tool),
    do:
      "Monitor existing external work without model polling. register returns immediately; completion is delivered at an idle session boundary. " <>
        "After registering, finish independent work and yield instead of polling. " <>
        "list/show inspect watches, stop only stops monitoring, forget clears retained output after delivery. " <>
        "github targets require repository (owner/repo), run_id and exact sha; background targets require task_id. " <>
        "No external work is started. Default is notification only; follow_up needs explicit host authorization."

  @impl true
  def schema(tool) do
    %{
      "type" => "object",
      "required" => ["action"],
      "additionalProperties" => false,
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ~w(register list show stop forget)},
        "source" => source_schema(tool.sources),
        "target" => %{
          "type" => "object",
          "properties" => %{
            "repository" => %{"type" => "string"},
            "run_id" => %{"type" => "string"},
            "sha" => %{"type" => "string"},
            "task_id" => %{"type" => "string"}
          },
          "additionalProperties" => true
        },
        "id" => %{"type" => "string"},
        "timeout_ms" => %{"type" => "integer", "minimum" => 1},
        "follow_up" => %{"type" => "boolean"}
      }
    }
  end

  defp source_schema([_source | _rest] = sources), do: %{"type" => "string", "enum" => sources}
  defp source_schema(_sources), do: %{"type" => "string"}

  @impl true
  def run(tool, %{"action" => "register", "follow_up" => true}, _context)
      when not tool.allow_follow_up,
      do:
        {:error,
         "This host authorizes notifications only. Register without follow_up; the person can enable Continue in the Tasks view."}

  def run(tool, args, context) do
    with {:ok, manager} <- manager(tool, context) do
      execute(manager, Map.put(args, "continuation_origin", "host")) |> result()
    end
  end

  @doc "Resolves the host service without reaching for a global runtime."
  @spec manager(tool :: struct(), context :: map()) ::
          {:ok, GenServer.server()} | {:error, term()}
  def manager(%{manager: resolve}, context) when is_function(resolve, 1), do: resolve.(context)
  def manager(%{manager: server}, _context), do: {:ok, server}

  @doc "Trusted host command entry point; callers decide follow-up authority."
  @spec execute(manager :: GenServer.server(), args :: map()) :: term()
  def execute(manager, %{"action" => "register", "source" => source, "target" => target} = args),
    do:
      Watches.register(manager, source, target,
        timeout_ms: Map.get(args, "timeout_ms", 3_600_000),
        follow_up: Map.get(args, "follow_up", false),
        continuation_origin: Map.get(args, "continuation_origin", "host")
      )

  def execute(manager, %{"action" => "list"}), do: {:ok, Watches.list(manager)}
  def execute(manager, %{"action" => "show", "id" => id}), do: Watches.get(manager, id)
  def execute(manager, %{"action" => "stop", "id" => id}), do: Watches.stop(manager, id)
  def execute(manager, %{"action" => "forget", "id" => id}), do: Watches.forget(manager, id)
  def execute(_manager, _args), do: {:error, :invalid_watch_action}

  @doc "Formats inspection for people; structured tool evidence retains the complete record."
  @spec format(value :: map() | [map()]) :: String.t()
  def format([]), do: "No watches."
  def format(watches) when is_list(watches), do: Enum.map_join(watches, "\n\n", &format/1)

  def format(watch) when is_map(watch) do
    mode = if watch["follow_up"], do: "automatic follow-up", else: "notification only"

    target =
      Enum.map_join(watch["target"] || %{}, ", ", fn {key, value} ->
        "#{key}: #{if is_binary(value), do: value, else: JSON.encode!(value)}"
      end)

    [
      "#{watch["id"]} · #{watch["source"]} · #{watch["status"]}",
      target,
      "Deadline: #{watch["deadline_at"]} · #{mode} · delivery #{watch["delivery"]}",
      if(is_map(watch["result"]), do: "Outcome: #{watch["result"]["outcome"]}"),
      get_in(watch, ["result", "summary"]),
      get_in(watch, ["result", "url"]),
      get_in(watch, ["result", "logs"])
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp result({:ok, value}),
    do: {:ok, Result.new(format(value), structured_content: %{"watch" => value})}

  defp result({:error, reason}), do: {:error, inspect(reason)}
end
