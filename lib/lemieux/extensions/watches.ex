defmodule Lemieux.Extensions.Watches do
  @moduledoc """
  Durable, bounded observation of work outside an ordinary session.

  This extension equips the optional `watch` tool. Hosts start `Server`
  explicitly with a `Lemieux.Jobs.Journal`, a session id and a map of
  `{module, state}` sources implementing `Source`; adding Lemieux starts
  nothing. `lmx` mounts one automatically for each equipped session.

  Registration does not start external work. Stop only stops observation.
  Recovery re-observes the stored target and re-delivers recorded results to
  the original session. Results wait until that session is idle, then use
  `Lemieux.Session.deliver_notification/3`. Its durable receipt provides
  at-most-once follow-up admission across a crash; an interrupted admission
  can leave a recorded result without inference, never an automatic replay.

  `follow_up` is host authorization, default false. A host may also supply
  `:authorize` to the server, checked again on delivery. The tool cannot ask
  for continuation unless its host sets `allow_follow_up: true`. Neither
  registration nor history changes session permissions or remaining budgets.
  Logs are external data; they are explicitly labelled in the follow-up.
  """

  @behaviour Lemieux.Extension
  alias Lemieux.Entry
  alias Lemieux.Extensions.Watches.Tool
  alias Lemieux.Harness
  alias Lemieux.Tool.Override
  alias Lemieux.Tool.Result

  @impl true
  def apply(harness, opts) do
    tool = Tool.new(opts)

    equipped =
      Harness.update_tools(harness, fn tools ->
        tools =
          if Keyword.get(opts, :auto_background, false),
            do: track_background(tools, tool),
            else: tools

        if Keyword.get(opts, :equip_tool, true), do: tools ++ [tool], else: tools
      end)

    %{equipped | commands: equipped.commands ++ Keyword.get(opts, :commands, [])}
  end

  defp track_background(tools, watcher) do
    Enum.map(tools, fn tool ->
      if Lemieux.Tool.name(tool) == "bash" do
        Override.new!(tool,
          digest: "lemieux-native-background-v1",
          after: fn result, args, context -> track(result, args, context, watcher) end
        )
      else
        tool
      end
    end)
  end

  defp track(
         {:ok, %Result{structured_content: %{"task_id" => id}} = result},
         %{"background" => true} = args,
         context,
         tool
       ) do
    timeout =
      case args["background_timeout_ms"] do
        ms when is_integer(ms) and ms > 0 -> min(ms, 86_400_000)
        _default -> 3_600_000
      end

    with {:ok, manager} <- Tool.manager(tool, context),
         {:ok, watch} <-
           register(manager, "background", %{"task_id" => id},
             timeout_ms: timeout,
             label: args["command"]
           ) do
      {:ok,
       %{
         result
         | model_text:
             "Background task #{id} started and is tracked in the Tasks view. Completion will notify this session. Continue independent work and yield instead of polling.",
           structured_content: Map.put(result.structured_content, "background_watch", watch)
       }}
    else
      error ->
        {:ok,
         %{
           result
           | model_text:
               result.model_text <> "\nAutomatic monitoring unavailable: #{inspect(error)}",
             structured_content:
               Map.put(result.structured_content, "background_tracking_error", inspect(error))
         }}
    end
  catch
    :exit, _reason ->
      {:ok,
       %{
         result
         | model_text: result.model_text <> "\nAutomatic monitoring is disconnected.",
           structured_content:
             Map.put(
               result.structured_content,
               "background_tracking_error",
               "Monitoring is disconnected"
             )
       }}
  end

  defp track({:ok, _value} = result, %{"task_id" => id, "cancel" => true}, context, tool) do
    with {:ok, manager} <- Tool.manager(tool, context) do
      manager
      |> list()
      |> Enum.filter(&(&1["source"] == "background" and &1["target"]["task_id"] == id))
      |> Enum.each(&stop(manager, &1["id"]))
    end

    result
  catch
    :exit, _reason -> result
  end

  defp track(result, _args, _context, _tool), do: result

  @doc "Registers a pinned target. Options: timeout_ms (one hour), follow_up (the host default)."
  @spec register(
          server :: GenServer.server(),
          source :: String.t(),
          target :: map(),
          opts :: keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def register(server, source, target, opts \\ []),
    do: GenServer.call(server, {:register, source, target, opts})

  @doc "Returns the currently mounted host's continuation default."
  @spec defaults(server :: GenServer.server()) :: %{follow_up: boolean()}
  def defaults(server), do: GenServer.call(server, :defaults)

  @doc "Lists bounded session watch records, including delivery and retention state."
  @spec list(server :: GenServer.server()) :: [map()]
  def list(server), do: GenServer.call(server, :list)

  @doc "Inspects a watch by its exact id."
  @spec get(server :: GenServer.server(), id :: String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(server, id), do: GenServer.call(server, {:get, id})

  @doc "Stops monitoring; never cancels the source activity."
  @spec stop(server :: GenServer.server(), id :: String.t()) :: {:ok, map()} | {:error, term()}
  def stop(server, id), do: GenServer.call(server, {:stop, id})

  @doc "Reconnects the original session; sources continue to run while it is disconnected."
  @spec attach(server :: GenServer.server(), session :: pid(), opts :: keyword()) ::
          :ok | {:error, :wrong_session | :disconnected}
  def attach(server, session, opts \\ []), do: GenServer.call(server, {:attach, session, opts})

  @doc "Forgets retained logs after delivery. The small idempotency record remains."
  @spec forget(server :: GenServer.server(), id :: String.t()) :: {:ok, map()} | {:error, term()}
  def forget(server, id), do: GenServer.call(server, {:forget, id})

  @doc "Sets explicit human continuation authority before a result has been delivered."
  @spec follow_up(server :: GenServer.server(), id :: String.t(), enabled? :: boolean()) ::
          {:ok, map()} | {:error, term()}
  def follow_up(server, id, enabled?) when is_boolean(enabled?),
    do: GenServer.call(server, {:follow_up, id, enabled?})

  @doc "Lists the host's configured source names without exposing reader commands or credentials."
  @spec sources(server :: GenServer.server()) :: [String.t()]
  def sources(server), do: GenServer.call(server, :sources)

  @doc """
  Whether this prompt registered a watch and has not stopped it.

  Stop policies can yield to an external completion instead of nudging an
  unfinished plan into another request. Read only the current prompt's
  entries: a previous task's watch cannot suppress today's continuation.
  A completion queued during the prompt needs the same idle boundary, so
  the recorded registration remains a reason to yield until then.
  """
  @spec waiting?(entries :: [Entry.t()]) :: boolean()
  def waiting?(entries) do
    entries
    |> Enum.reduce(%{}, &observe_wait/2)
    |> Map.values()
    |> Enum.any?()
  end

  defp observe_wait(
         %{
           type: :tool_result,
           payload: %{
             "name" => "watch",
             "error" => false,
             "arguments" => %{"action" => action},
             "structured_content" => %{"watch" => %{"id" => id, "status" => status}}
           }
         },
         pending
       )
       when action in ~w(register stop),
       do: Map.put(pending, id, action == "register" and status == "watching")

  defp observe_wait(
         %{
           type: :tool_result,
           payload: %{
             "error" => false,
             "structured_content" => %{"background_watch" => %{"id" => id, "status" => status}}
           }
         },
         pending
       ),
       do: Map.put(pending, id, status == "watching")

  defp observe_wait(_entry, pending), do: pending
end
