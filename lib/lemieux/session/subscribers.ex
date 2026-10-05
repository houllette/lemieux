defmodule Lemieux.Session.Subscribers do
  @moduledoc false

  @max_transient_queue 1_000

  defstruct pids: MapSet.new(), refs: %{}

  @type t :: %__MODULE__{pids: MapSet.t(pid()), refs: %{optional(pid()) => reference()}}

  @spec new(pid() | [pid()] | nil) :: t()
  def new(subscriber) do
    pids = normalize(subscriber)
    %__MODULE__{pids: pids, refs: Map.new(pids, &{&1, Process.monitor(&1)})}
  end

  @spec add(t(), pid()) :: t()
  def add(%__MODULE__{pids: pids} = subscribers, pid) when is_pid(pid) do
    if MapSet.member?(pids, pid) do
      subscribers
    else
      %{
        subscribers
        | pids: MapSet.put(pids, pid),
          refs: Map.put(subscribers.refs, pid, Process.monitor(pid))
      }
    end
  end

  @spec remove(t(), pid()) :: t()
  def remove(%__MODULE__{} = subscribers, pid) when is_pid(pid) do
    case Map.pop(subscribers.refs, pid) do
      {nil, _refs} ->
        subscribers

      {ref, refs} ->
        Process.demonitor(ref, [:flush])
        %{subscribers | pids: MapSet.delete(subscribers.pids, pid), refs: refs}
    end
  end

  @spec down(t(), reference(), pid()) :: {:ok, t()} | :error
  def down(%__MODULE__{} = subscribers, ref, pid) do
    case Map.get(subscribers.refs, pid) do
      ^ref ->
        {:ok,
         %{
           subscribers
           | pids: MapSet.delete(subscribers.pids, pid),
             refs: Map.delete(subscribers.refs, pid)
         }}

      _other ->
        :error
    end
  end

  @spec broadcast(t(), String.t(), term()) :: :ok
  def broadcast(%__MODULE__{pids: pids}, session_id, event) do
    Enum.each(pids, &deliver(&1, session_id, event))
  end

  defp deliver(subscriber, session_id, {kind, _payload} = event)
       when kind in [:text_delta, :thinking_delta, :tool_delta] do
    case Process.info(subscriber, :message_queue_len) do
      {:message_queue_len, length} when length < @max_transient_queue ->
        send(subscriber, {:lemieux, session_id, event})

      _slow_or_dead ->
        :ok
    end
  end

  defp deliver(subscriber, session_id, event),
    do: send(subscriber, {:lemieux, session_id, event})

  defp normalize(nil), do: MapSet.new()
  defp normalize(subscriber) when is_pid(subscriber), do: MapSet.new([subscriber])

  defp normalize(subscribers) when is_list(subscribers) do
    if Enum.all?(subscribers, &is_pid/1) do
      MapSet.new(subscribers)
    else
      invalid_subscriber!()
    end
  end

  defp normalize(_subscriber), do: invalid_subscriber!()

  defp invalid_subscriber! do
    raise ArgumentError, ":subscriber must be a pid, a list of pids, or nil"
  end
end
