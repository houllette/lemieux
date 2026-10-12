defmodule Lemieux.CLI.ACP.Wire do
  @moduledoc false

  alias Lemieux.Entry

  def initialize(version) do
    info = %{"name" => "lmx", "version" => Lemieux.version()}
    meta = %{"lemieux" => %{"question" => true, "steer" => true}}

    if version == 2 do
      %{
        "protocolVersion" => 2,
        "info" => info,
        "authMethods" => [],
        "capabilities" => %{"session" => %{"mcp" => %{"stdio" => true}}},
        "_meta" => meta
      }
    else
      %{
        "protocolVersion" => 1,
        "agentInfo" => info,
        "authMethods" => [],
        "agentCapabilities" => %{
          "loadSession" => true,
          "sessionCapabilities" => %{"list" => %{}, "resume" => %{}, "close" => %{}}
        },
        "_meta" => meta
      }
    end
  end

  def entry(version, %Entry{type: type, id: id, payload: payload})
      when type in [:user, :assistant] do
    prefix = if type == :user, do: "user", else: "agent"
    text = payload["text"] || Enum.map_join(payload["content"] || [], &Map.get(&1, "text", ""))
    content = %{"type" => "text", "text" => text}

    if version == 2 do
      %{"sessionUpdate" => prefix <> "_message", "messageId" => id, "content" => [content]}
    else
      %{"sessionUpdate" => prefix <> "_message_chunk", "content" => content, "messageId" => id}
    end
  end

  def entry(_version, %Entry{type: :tool_result, payload: payload}) do
    %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => payload["call_id"],
      "status" => if(payload["error"], do: "failed", else: "completed"),
      "rawOutput" => payload["output"]
    }
  end

  def entry(_version, _entry), do: nil

  def chunk(kind, %{id: id, text: text}) do
    %{
      "sessionUpdate" => kind,
      "messageId" => id,
      "content" => %{"type" => "text", "text" => text}
    }
  end

  def tool(version, call) do
    %{
      "sessionUpdate" => if(version == 2, do: "tool_call_update", else: "tool_call"),
      "toolCallId" => call.id,
      "title" => call.name,
      "name" => call.name,
      "status" => "pending",
      "rawInput" => call.arguments
    }
  end

  def permission(version, session_id, call) do
    options = [
      %{"optionId" => "allow", "name" => "Allow once", "kind" => "allow_once"},
      %{"optionId" => "deny", "name" => "Reject once", "kind" => "reject_once"}
    ]

    base = %{"sessionId" => session_id, "options" => options}

    if version == 2,
      do: Map.merge(base, %{"title" => call.name, "description" => JSON.encode!(call.arguments)}),
      else: Map.put(base, "toolCall", tool(version, call) |> Map.delete("sessionUpdate"))
  end

  def stop_reason(:cancelled), do: "cancelled"
  def stop_reason(:max_turns), do: "max_turn_requests"
  def stop_reason(:stop), do: "end_turn"
  def stop_reason(_reason), do: "refusal"
end
