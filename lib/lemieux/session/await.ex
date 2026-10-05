defmodule Lemieux.Session.Await do
  @moduledoc """
  Prompting a session and waiting for the work to finish.

  What `Lemieux.Session.await/3` and `Lemieux.run/2` are built on. A session
  answers a prompt by streaming events to its subscribers, which is the right
  shape for a screen and the wrong one for a job that wants an answer: every
  embedder was writing the same receive loop, and the ones that subscribed
  their own process kept receiving that session's events long after they had
  stopped caring.

  So the waiting is done through a relay: a process linked to the caller that
  subscribes before the prompt is sent — nothing the prompt starts can arrive
  before somebody is listening — forwards each event tagged with a reference,
  and is unsubscribed and stopped when the wait ends. Whatever the session
  sends afterwards goes to a process that no longer exists rather than into
  the caller's mailbox.
  """

  alias Lemieux.Entry
  alias Lemieux.Session
  alias Lemieux.Usage

  @typedoc "What one prompt produced; see `Lemieux.Session.await/3`."
  @type result :: %{
          session_id: String.t(),
          text: String.t(),
          stop_reason: term(),
          error: term() | nil,
          usage: Usage.t(),
          entries: [Entry.t()]
        }

  @doc """
  Prompts `session` and waits for `{:finished, _}`. See `Lemieux.Session.await/3`.

  The session is monitored for the whole wait. One that goes down before it
  finishes — or was already gone — answers `{:error, {:session_down, reason}}`
  with its exit reason, instead of a wait that never ends: nothing else would
  ever send the `:finished` the loop is waiting for.
  """
  @spec run(session :: Session.session(), text :: String.t(), opts :: keyword()) ::
          {:ok, result()} | {:error, {:session_down, term()} | :timeout | term()}
  def run(session, text, opts) when is_binary(text) and is_list(opts) do
    case GenServer.whereis(session) do
      pid when is_pid(pid) -> watch(pid, text, opts)
      _gone -> {:error, {:session_down, :noproc}}
    end
  end

  defp watch(session, text, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    on_event = Keyword.get(opts, :on_event)
    monitor = Process.monitor(session)
    parent = self()
    tag = make_ref()
    relay = spawn_link(fn -> relay(parent, tag) end)

    try do
      with :ok <- call(fn -> Session.subscribe(session, relay) end),
           :ok <- call(fn -> Session.prompt(session, text) end) do
        collect(tag, monitor, on_event, timeout, %{events: [], entries: [], error: nil, id: nil})
      end
    after
      Process.demonitor(monitor, [:flush])
      call(fn -> Session.unsubscribe(session, relay) end)
      send(relay, :stop)
    end
  end

  # A session that died between the lookup and a call answers the call with
  # an exit. That is the same fact the monitor reports during the wait, so it
  # gets the same answer rather than taking the caller down with it.
  defp call(fun) do
    fun.()
  catch
    :exit, {reason, {GenServer, :call, _args}} -> {:error, {:session_down, reason}}
  end

  defp relay(parent, tag) do
    receive do
      {:lemieux, id, event} ->
        send(parent, {tag, id, event})
        relay(parent, tag)

      :stop ->
        :ok
    end
  end

  defp collect(tag, monitor, on_event, timeout, acc) do
    receive do
      {^tag, id, event} ->
        notify(on_event, event)
        acc = note(%{acc | id: id}, event)

        case event do
          {:finished, stop_reason} -> {:ok, result(acc, stop_reason)}
          _other -> collect(tag, monitor, on_event, timeout, acc)
        end

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, {:session_down, reason}}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp notify(nil, _event), do: :ok
  defp notify(fun, event) when is_function(fun, 1), do: fun.(event)

  defp note(acc, {:entry, %Entry{} = entry}), do: %{acc | entries: [entry | acc.entries]}
  defp note(acc, {:error, reason}), do: %{acc | error: reason}
  defp note(acc, _event), do: acc

  defp result(acc, stop_reason) do
    entries = Enum.reverse(acc.entries)

    %{
      session_id: acc.id,
      text: answer(entries),
      stop_reason: stop_reason,
      error: acc.error,
      usage: entries |> Enum.map(& &1.usage) |> Enum.filter(&is_map/1) |> Usage.sum(),
      entries: entries
    }
  end

  # The last answer the model gave, not the last text anywhere: a partial
  # answer kept from a retried request is a record, and the answer is what
  # the retry said.
  defp answer(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :assistant and &1.payload["partial"] != true))
    |> text()
  end

  defp text(%Entry{payload: %{"content" => content}}) when is_list(content) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join(&Map.get(&1, "text", ""))
  end

  defp text(_entry), do: ""
end
