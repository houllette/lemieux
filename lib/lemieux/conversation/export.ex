defmodule Lemieux.Conversation.Export do
  @moduledoc """
  A session's conversation as Markdown a person can read and share.

  What `/export` writes. The transcript is kept as JSON lines because it is
  the record resume and replay read, and it is complete — request snapshots,
  harness snapshots, receipts — which is exactly what makes it unreadable as
  an account of what happened. This is the account: what the person asked,
  what the agent said, and each tool it used with a bounded excerpt of what
  came back.

  A pure function of a snapshot, so what an export looks like is tested
  without a session, a file or a front end.
  """

  alias Lemieux.ID.Shorthand

  @max_output_lines 20
  @max_argument_chars 200

  @doc """
  The Markdown for `snapshot` — `Lemieux.Session.snapshot/1`'s map, or
  anything with `:id` and `:entries` (and optionally `:model` and `:cwd`).
  """
  @spec markdown(snapshot :: map()) :: String.t()
  def markdown(%{id: id, entries: entries} = snapshot) when is_list(entries) do
    header =
      [
        "# lmx session #{Shorthand.of(id)}",
        "",
        "- Session: `#{id}`",
        field("Model", Map.get(snapshot, :model)),
        field("Working directory", Map.get(snapshot, :cwd))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    body = entries |> Enum.flat_map(&section/1) |> Enum.join("\n\n")

    header <> "\n\n" <> body <> "\n"
  end

  defp field(_label, nil), do: nil
  defp field(label, value), do: "- #{label}: `#{value}`"

  defp section(%{type: :user, payload: %{"text" => text}}),
    do: ["## You", String.trim(text)]

  defp section(%{type: :assistant, payload: payload}) do
    text =
      payload
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} -> [text]
        _other -> []
      end)
      |> Enum.join("\n\n")
      |> String.trim()

    calls = payload |> Map.get("tool_calls", []) |> Enum.map(&call/1)

    case {text, calls} do
      {"", []} -> []
      {"", calls} -> [Enum.join(calls, "\n")]
      {text, []} -> ["## lmx", text]
      {text, calls} -> ["## lmx", text, Enum.join(calls, "\n")]
    end
  end

  defp section(%{type: :tool_result, payload: payload}), do: [result(payload)]
  defp section(%{type: :compaction}), do: ["_The earlier conversation was summarised here._"]
  defp section(%{type: :cancelled}), do: ["_Cancelled._"]

  defp section(%{type: :error, payload: payload}),
    do: ["> error: #{payload["reason"] || inspect(payload)}"]

  defp section(_entry), do: []

  defp call(%{"name" => name} = call) do
    case arguments(Map.get(call, "arguments")) do
      "" -> "- **#{name}**"
      arguments -> "- **#{name}** `#{arguments}`"
    end
  end

  defp call(_call), do: "- a tool call"

  # The argument a person would recognise the call by: a command, a path, a
  # pattern. The whole map would be a wall of JSON for an `edit`.
  defp arguments(%{} = arguments) do
    arguments
    |> Map.values()
    |> Enum.find(&is_binary/1)
    |> case do
      nil ->
        ""

      value ->
        value
        |> String.split("\n", parts: 2)
        |> List.first()
        |> String.slice(0, @max_argument_chars)
        |> String.replace("`", "'")
    end
  end

  defp arguments(_arguments), do: ""

  defp result(payload) do
    name = payload["name"] || "tool"
    mark = if payload["error"] == true, do: "failed", else: "result"
    output = payload |> Map.get("output") |> excerpt()

    case output do
      "" -> "<details><summary>#{name} #{mark}</summary></details>"
      output -> "<details><summary>#{name} #{mark}</summary>\n\n```\n#{output}\n```\n\n</details>"
    end
  end

  defp excerpt(output) when is_binary(output) do
    lines = output |> String.trim_trailing() |> String.split("\n")
    shown = Enum.take(lines, @max_output_lines) |> Enum.join("\n") |> String.replace("```", "'''")
    more = length(lines) - @max_output_lines

    if more > 0, do: shown <> "\n… #{more} more lines", else: shown
  end

  defp excerpt(_output), do: ""
end
