defmodule Lemieux.A2A.SSE do
  @moduledoc """
  Incremental, bounded SSE framing for the A2A 1.0 JSON-RPC binding. A host
  writes [`snapshot/2`](Lemieux.A2A.SSE.html#snapshot/2) first and
  [`event/3`](Lemieux.A2A.SSE.html#event/3) for server mailbox updates. End the
  stream on a terminal or interrupted status. EOF alone is never completion.
  """
  alias Lemieux.A2A.{JSONRPC, Task}
  @doc "The first frame of a stream: the whole task, answering request `id`."
  @spec snapshot(id :: term(), task :: Task.t()) :: String.t()
  def snapshot(id, task), do: frame(JSONRPC.reply(id, %{"task" => Task.to_json(task)}))

  @doc """
  The frame for one server update: `{:status, task}` becomes a status update,
  and `{:delta, text}` an artifact update that appends `text` to the task's
  artifact.
  """
  @spec event(id :: term(), task :: Task.t(), event :: term()) :: String.t()
  def event(id, task, {:status, updated}) do
    status = Task.to_json(updated)["status"]

    frame(
      JSONRPC.reply(id, %{
        "statusUpdate" => %{
          "taskId" => task.id,
          "contextId" => task.context_id,
          "status" => status,
          "metadata" => updated.metadata
        }
      })
    )
  end

  def event(id, task, {:delta, text}) do
    frame(
      JSONRPC.reply(id, %{
        "artifactUpdate" => %{
          "taskId" => task.id,
          "contextId" => task.context_id,
          "artifact" => %{"artifactId" => "#{task.id}:0", "parts" => [%{"text" => text}]},
          "append" => true
        }
      })
    )
  end

  @doc "One SSE `data:` frame holding `envelope`."
  @spec frame(envelope :: map()) :: String.t()
  def frame(envelope), do: "data: " <> JSON.encode!(envelope) <> "\n\n"

  @doc """
  Parses SSE input as it arrives.

  Appends `chunk` to the `buffer` the previous call returned and answers the
  complete JSON-RPC envelopes so far with the new buffer. A frame larger than
  `max_bytes`, finished or not, is an error rather than an allocation.
  """
  @spec feed(buffer :: binary(), chunk :: binary(), max_bytes :: pos_integer()) ::
          {:ok, binary(), [map()]} | {:error, String.t()}
  def feed(buffer, chunk, max_bytes) do
    # Preserve CR at a packet boundary until the following LF arrives.
    data = (buffer <> chunk) |> String.replace("\r\n", "\n")
    parts = String.split(data, "\n\n")
    tail = List.last(parts)
    frames = Enum.drop(parts, -1)

    if byte_size(tail) > max_bytes or Enum.any?(frames, &(byte_size(&1) > max_bytes)) do
      {:error, "SSE frame exceeds limit"}
    else
      Enum.reduce_while(frames, {:ok, tail, []}, &parse_frame/2)
    end
  end

  defp parse_frame(frame, {:ok, tail, parsed}) do
    data =
      frame
      |> String.split("\n")
      |> Enum.flat_map(fn
        "data:" <> value -> [String.trim_leading(value, " ")]
        _ -> []
      end)
      |> Enum.join("\n")

    parsed_frame(data, tail, parsed)
  end

  defp parsed_frame("", tail, parsed), do: {:cont, {:ok, tail, parsed}}

  defp parsed_frame(json, tail, parsed) do
    case JSONRPC.decode(json) do
      {:ok, envelope} -> {:cont, {:ok, tail, parsed ++ [envelope]}}
      _ -> {:halt, {:error, "invalid SSE JSON-RPC frame"}}
    end
  end
end
