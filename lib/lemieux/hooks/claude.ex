defmodule Lemieux.Hooks.Claude do
  @moduledoc """
  The names Claude Code uses for the things Lemieux names differently.

  A hook or permission rule written for Claude Code says `Bash`, `Edit`,
  `tool_input.file_path` and `PreToolUse`; Lemieux calls the same things
  `bash`, `edit`, `path` and `preToolUse`. Nothing about the scripts differs
  except the spelling, so the translation lives in one table here instead of
  in every script somebody would otherwise have to rewrite — and a
  mistranslation is fixed once, for hooks and permission rules alike.

  The table goes one way per question. `tool_aliases/2` answers "which Claude
  names does this Lemieux tool answer to?", which is what a matcher needs.
  `lemieux_tools/1` answers the reverse for a permission rule. Fields are
  translated on the way into a Claude-dialect script (`to_claude_input/2`) and
  back out of an `updatedInput` it returns (`from_claude_input/2`).
  """

  # Each Lemieux tool and the Claude Code tool names that act like it. A tool
  # that edits files answers to every Claude editing name, because a Claude
  # hook matching `Edit|MultiEdit|Write` means "whatever changes a file".
  @tool_aliases %{
    "bash" => ["Bash"],
    "read" => ["Read"],
    "write" => ["Write"],
    "edit" => ["Edit", "MultiEdit"],
    "apply_patch" => ["Edit", "MultiEdit", "Write"],
    "grep" => ["Grep"],
    "glob" => ["Glob"],
    "web_fetch" => ["WebFetch"],
    "web_search" => ["WebSearch"],
    "delegate" => ["Task"],
    "todo" => ["TodoWrite"]
  }

  # The Claude name a Claude-dialect script is shown. Tools with no exact
  # counterpart keep their own name rather than borrowing one whose input
  # fields they do not have: a formatter keyed on `Edit` reads
  # `tool_input.file_path`, which `apply_patch` does not carry.
  @primary %{
    "bash" => "Bash",
    "read" => "Read",
    "write" => "Write",
    "edit" => "Edit",
    "grep" => "Grep",
    "glob" => "Glob",
    "web_fetch" => "WebFetch",
    "web_search" => "WebSearch",
    "delegate" => "Task",
    "todo" => "TodoWrite"
  }

  # Claude rule and matcher names, and the Lemieux tools each covers. Claude's
  # `Edit` and `Read` rules deliberately cover every tool of that kind.
  @claude_tools %{
    "bash" => ["bash"],
    "edit" => ["edit", "write", "apply_patch"],
    "multiedit" => ["edit", "write", "apply_patch"],
    "write" => ["write", "edit", "apply_patch"],
    "read" => ["read", "grep", "glob"],
    "grep" => ["grep"],
    "glob" => ["glob"],
    "webfetch" => ["web_fetch"],
    "websearch" => ["web_search"],
    "task" => ["delegate"],
    "todowrite" => ["todo"]
  }

  # Input fields, Lemieux name to Claude name.
  @fields %{
    "path" => "file_path",
    "old" => "old_string",
    "new" => "new_string",
    "timeout_ms" => "timeout",
    "background" => "run_in_background"
  }

  # `path` is `file_path` only for tools that take one file. For `grep` and
  # `glob` Claude also says `path`, and meaning the same thing.
  @file_path_tools ["read", "write", "edit"]

  @events %{
    session_start: "SessionStart",
    attention: "Notification",
    user_prompt: "UserPromptSubmit",
    before_tool_call: "PreToolUse",
    after_tool_call: "PostToolUse",
    stop: "Stop",
    session_end: "SessionEnd"
  }

  @doc """
  The Claude Code names the Lemieux tool `name` answers to.

  An MCP tool (descriptor origin `"mcp"`) answers to `mcp__` plus its
  Lemieux name, which is how Claude spells `server__tool`.
  """
  @spec tool_aliases(name :: String.t(), descriptor :: map() | nil) :: [String.t()]
  def tool_aliases(name, descriptor \\ nil) when is_binary(name) do
    Map.get(@tool_aliases, name, []) ++ mcp_alias(name, descriptor)
  end

  @doc """
  The name a Claude-dialect script is told the tool has: its Claude
  counterpart where there is an exact one, `mcp__…` for an MCP tool, and its
  own name otherwise.
  """
  @spec tool_name(name :: String.t(), descriptor :: map() | nil) :: String.t()
  def tool_name(name, descriptor \\ nil) when is_binary(name) do
    case {Map.fetch(@primary, name), mcp_alias(name, descriptor)} do
      {{:ok, primary}, _mcp} -> primary
      {:error, [mcp]} -> mcp
      {:error, []} -> name
    end
  end

  @doc """
  The Lemieux tools a Claude tool name refers to, or `:unknown`.

  Case-insensitive, so `Bash`, `bash` and `BASH` agree. A Lemieux tool name
  that is not a Claude name answers `:unknown`; callers treat it as itself.
  """
  @spec lemieux_tools(claude_name :: String.t()) :: [String.t()] | :unknown
  def lemieux_tools(claude_name) when is_binary(claude_name) do
    Map.get(@claude_tools, String.downcase(claude_name), :unknown)
  end

  @doc """
  `input` with Claude's field names added beside Lemieux's.

  Both spellings are present: a script written for Claude reads
  `file_path`, one written for Lemieux reads `path`, and neither has to know
  which host it is under.
  """
  @spec to_claude_input(tool :: String.t(), input :: map()) :: map()
  def to_claude_input(tool, input) when is_binary(tool) and is_map(input) do
    Enum.reduce(input, input, fn {field, value}, acc ->
      case claude_field(tool, field) do
        nil -> acc
        claude -> Map.put_new(acc, claude, value)
      end
    end)
  end

  @doc """
  An `updatedInput` a Claude-dialect script returned, with Claude field names
  turned back into the tool's own.

  A field is renamed only when the tool's schema has the Lemieux name and the
  script did not also send it, so a script that already speaks Lemieux is
  untouched. Anything the schema does not know is left for the tool to
  reject, which says more than silently dropping it would.
  """
  @spec from_claude_input(input :: map(), properties :: map()) :: map()
  def from_claude_input(input, properties) when is_map(input) and is_map(properties) do
    Enum.reduce(@fields, input, fn {lemieux, claude}, acc ->
      rename(acc, claude, lemieux, properties)
    end)
  end

  @doc "The Claude Code spelling of a hook event, where Claude has one."
  @spec event_name(event :: atom()) :: String.t() | nil
  def event_name(event) when is_atom(event), do: Map.get(@events, event)

  defp rename(input, claude, lemieux, properties) do
    if Map.has_key?(input, claude) and Map.has_key?(properties, lemieux) and
         not Map.has_key?(input, lemieux) do
      {value, rest} = Map.pop(input, claude)
      Map.put(rest, lemieux, value)
    else
      input
    end
  end

  defp claude_field(tool, "path") when tool in @file_path_tools, do: "file_path"
  defp claude_field(_tool, "path"), do: nil
  defp claude_field(_tool, field), do: Map.get(@fields, field)

  defp mcp_alias(name, %{"origin" => %{"type" => "mcp"}}), do: ["mcp__" <> name]
  defp mcp_alias(_name, _descriptor), do: []
end
