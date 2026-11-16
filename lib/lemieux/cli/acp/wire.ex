defmodule Lemieux.CLI.ACP.Wire do
  @moduledoc false

  alias Lemieux.Entry
  alias Lemieux.Environment.Local

  @spec initialize(version :: 1 | 2, auth_methods :: [map()]) :: map()
  def initialize(version, auth_methods \\ []) do
    info = %{"name" => "lmx", "version" => Lemieux.version()}

    namespace = if version == 2, do: "com.github.houllette.lemieux/capabilities", else: "lemieux"

    meta = %{
      namespace => %{"question" => true, "steer" => true, "fork" => true, "configure" => true}
    }

    if version == 2 do
      %{
        "protocolVersion" => 2,
        "info" => info,
        "authMethods" => auth_methods,
        "capabilities" => %{"session" => %{"mcp" => %{"stdio" => %{}}}},
        "_meta" => meta
      }
    else
      %{
        "protocolVersion" => 1,
        "agentInfo" => info,
        "authMethods" => auth_methods,
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
      "content" => [
        %{
          "type" => "content",
          "content" => %{"type" => "text", "text" => output(payload["output"])}
        }
      ],
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

  @spec tool(version :: 1 | 2, call :: map(), cwd :: Path.t() | nil) :: map()
  def tool(version, call, cwd \\ nil) do
    packet = %{
      "sessionUpdate" => if(version == 2, do: "tool_call_update", else: "tool_call"),
      "toolCallId" => call.id,
      "title" => call.name,
      "name" => call.name,
      "kind" => kind(call.name),
      "status" => "pending",
      "rawInput" => call.arguments
    }

    case {cwd, call.arguments["path"]} do
      {cwd, path} when is_binary(cwd) and is_binary(path) ->
        case Local.confined(cwd, path) do
          {:ok, full} -> Map.put(packet, "locations", [%{"path" => full}])
          _outside -> packet
        end

      _no_location ->
        packet
    end
  end

  @spec tool_event(
          call_id :: String.t(),
          event :: :started | {:diff, Path.t(), String.t() | nil, String.t()},
          version :: 1 | 2
        ) :: map()
  def tool_event(call_id, event, version \\ 1)

  def tool_event(call_id, :started, _version),
    do: %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => call_id,
      "status" => "in_progress"
    }

  def tool_event(call_id, {:diff, path, old, new}, version) do
    %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => call_id,
      "content" => [diff(version, path, old, new)],
      "locations" => [%{"path" => path}]
    }
  end

  defp diff(1, path, old, new),
    do: %{"type" => "diff", "path" => path, "oldText" => old, "newText" => new}

  defp diff(2, path, old, new) do
    %{
      "type" => "diff",
      "changes" => [
        %{
          "operation" => if(is_nil(old), do: "add", else: "modify"),
          "path" => path,
          "fileType" => "text"
        }
      ],
      "patch" => %{"format" => "git_patch", "text" => patch(path, old, new)}
    }
  end

  defp patch(path, old, new) do
    before_path = quote_path("a/" <> path)
    after_path = quote_path("b/" <> path)
    {removed, before_text} = patch_lines(old || "", "-")
    {added, after_text} = patch_lines(new, "+")
    old_header = if is_nil(old), do: "/dev/null", else: before_path

    "diff --git #{before_path} #{after_path}\n--- #{old_header}\n+++ #{after_path}\n" <>
      "@@ -#{line_start(removed)},#{removed} +#{line_start(added)},#{added} @@\n" <>
      before_text <> after_text
  end

  defp line_start(0), do: 0
  defp line_start(_count), do: 1
  defp patch_lines("", _prefix), do: {0, ""}

  defp patch_lines(text, prefix) do
    newline? = String.ends_with?(text, "\n")
    lines = String.split(text, "\n")
    lines = if newline?, do: Enum.drop(lines, -1), else: lines
    body = Enum.map_join(lines, &(prefix <> &1 <> "\n"))
    suffix = if newline?, do: "", else: "\\ No newline at end of file\n"
    {length(lines), body <> suffix}
  end

  defp quote_path(path) do
    escaped =
      path
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end

  defp kind("read"), do: "read"
  defp kind(name) when name in ["write", "edit", "apply_patch"], do: "edit"
  defp kind(name) when name in ["bash", "elixir"], do: "execute"
  defp kind(name) when name in ["grep", "glob", "web_search"], do: "search"
  defp kind("web_fetch"), do: "fetch"
  defp kind(_name), do: "other"
  defp output(text) when is_binary(text), do: text
  defp output(value), do: JSON.encode!(value)

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
  def stop_reason(:length), do: "max_tokens"
  def stop_reason({:budget, _details}), do: "max_turn_requests"
  def stop_reason(:no_progress), do: "max_turn_requests"
  def stop_reason(:max_turns), do: "max_turn_requests"
  def stop_reason(:stop), do: "end_turn"
  def stop_reason(_reason), do: "refusal"
end
