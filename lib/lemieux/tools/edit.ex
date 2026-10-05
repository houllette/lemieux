defmodule Lemieux.Tools.Edit do
  @moduledoc """
  Replaces a string in a file.

  ## Why exact strings, and why uniqueness is enforced

  The obvious alternatives are worse in ways that are hard to see until they
  bite. A line-number edit goes wrong the moment the model's idea of the file
  is one edit stale, and it fails *silently* — the replacement lands, on the
  wrong line. A diff or patch format asks the model to produce something with
  syntax of its own, which it gets subtly wrong often enough to matter, and
  which fails in ways that need a parser to explain.

  Exact-string replacement fails loudly instead. If `old` is not in the file,
  nothing happens and the model is told. If `old` appears more than once, the
  edit is **refused with the count**, because "replace the first one" is a
  guess about which one was meant, and a wrong guess here silently corrupts a
  file the model believes it fixed. The model's answer is to include more
  surrounding context until the string is unique — which is exactly the
  information needed to make the edit unambiguous.

  `replace_all` exists for the case where every occurrence really is meant, a
  rename being the obvious one. It has to be asked for.

  ## Close is not a miss

  Exact does not mean brittle. Line endings, a byte-order mark, the line
  numbers `read` prints, trailing whitespace and indentation are all things a
  model gets wrong while meaning exactly one place, and
  `Lemieux.Tools.Edit.Match` finds that place — still only if there is one.
  Weaker models failed here more than anywhere else: they copied the text
  correctly, missed on a `\\r` they could not see, and repeated the call until
  the session's loop guard ended it. When nothing matches at all the refusal
  shows the closest region, which is usually the correction.

  The result shows the edited lines, numbered, so the model sees what the
  file now says rather than assuming it.

  ## Nothing is written unless something changed

  Every refusal leaves the file untouched, and `old == new` is itself a
  refusal: an edit that reports success without changing anything is how a
  model ends up in a loop, re-applying a fix that never applied.

  ## A file that changed underneath

  When the session has seen the file (see `Lemieux.Tool.FileState`) and it
  has changed since, the edit still applies — the old text had to match what
  is there now — but the result says so, so the model looks at what else
  changed before building on it.
  """

  @behaviour Lemieux.Tool

  alias Lemieux.Environment
  alias Lemieux.Tool
  alias Lemieux.Tool.FileState
  alias Lemieux.Tools.Edit.Match

  @snippet_context 2
  @snippet_lines 24

  @impl Lemieux.Tool
  def name, do: "edit"

  @impl Lemieux.Tool
  def description do
    """
    Replace a string in a file.

    The old string must match exactly one place, or the edit is refused —
    include enough surrounding lines to make it unique. Set replace_all to
    change every occurrence instead (for a rename, say). Copy the text as read,
    without the line numbers read prints; small differences in indentation or
    trailing whitespace are tolerated when they still point at one place. The
    result shows the edited lines.
    """
  end

  @impl Lemieux.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path relative to the working directory."
        },
        "old" => %{
          "type" => "string",
          "description" => "The text to replace, including its indentation."
        },
        "new" => %{"type" => "string", "description" => "What to replace it with."},
        "replace_all" => %{
          "type" => "boolean",
          "description" => "Replace every occurrence instead of requiring exactly one."
        }
      },
      "required" => ["path", "old", "new"],
      "additionalProperties" => false
    }
  end

  @impl Lemieux.Tool
  def metadata do
    %{
      effects: %{class: "write", resource_types: ["file"]},
      runtime: %{concurrency: %{class: "exclusive"}}
    }
  end

  @impl Lemieux.Tool
  def run(%{"path" => path, "old" => old, "new" => new} = args, context)
      when is_binary(path) and is_binary(old) and is_binary(new) do
    environment = Environment.from_context(context)

    with {:ok, contents} <- read(environment, context.cwd, path),
         {:ok, replaced} <- replace(contents, path, old, new, args["replace_all"] == true),
         :ok <- write(environment, context.cwd, path, replaced.contents) do
      stale? = stale?(context, path, contents)
      FileState.record(context, path, FileState.fingerprint(replaced.contents))
      {:ok, report(path, replaced, stale?)}
    end
  end

  def run(_args, _context), do: {:error, "edit needs path, old and new"}

  defp read(environment, cwd, path) do
    case Environment.read_file(environment, cwd, path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :outside_worktree} -> {:error, "#{path}: is outside the working directory"}
      {:error, :enoent} -> {:error, "#{path}: no such file"}
      {:error, :eisdir} -> {:error, "#{path}: is a directory, not a file"}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp replace(contents, path, old, new, replace_all?) do
    case Match.replace(contents, old, new, replace_all?) do
      {:ok, replaced} ->
        {:ok, replaced}

      {:error, :empty} ->
        {:error, "the old string is empty; it would match everywhere"}

      {:error, :identical} ->
        {:error, "the old and new strings are identical, so this edit would change nothing"}

      {:error, {:ambiguous, strategy, count}} ->
        {:error, ambiguous(path, strategy, count)}

      {:error, :not_found} ->
        {:error, not_found(path, contents, old)}
    end
  end

  defp ambiguous(path, :exact, count) do
    "#{path}: the old string appears #{count} times. Include more surrounding lines to make " <>
      "it unique, or set replace_all if every occurrence should change."
  end

  defp ambiguous(path, strategy, count) do
    "#{path}: the old string is not in the file exactly, and #{describe(strategy)} it matches " <>
      "#{count} places. Read the file and copy the text you mean, with enough surrounding " <>
      "lines to make it unique."
  end

  defp not_found(path, contents, old) do
    base = "#{path}: the old string was not found. Read the file and copy the text exactly."

    case Match.closest(contents, old) do
      nil ->
        base

      {first, last, score} ->
        lines =
          contents
          |> String.replace("\r\n", "\n")
          |> String.split("\n")
          |> Enum.slice(first - 1, last - first + 1)
          |> Enum.map(&Tool.sanitize/1)

        percent = round(score * 100)

        base <>
          "\n\nThe closest text is lines #{first}-#{last} (#{percent}% similar):\n" <>
          (lines |> Enum.take(@snippet_lines) |> Tool.number_lines(first))
    end
  end

  defp write(environment, cwd, path, contents) do
    case Environment.write_file(environment, cwd, path, contents) do
      {:ok, _disposition} -> :ok
      {:error, :outside_worktree} -> {:error, "#{path}: is outside the working directory"}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp stale?(context, path, contents) do
    case FileState.seen(context, path) do
      {:ok, fingerprint} -> fingerprint != FileState.fingerprint(contents)
      _unseen_or_untracked -> false
    end
  end

  defp report(path, replaced, stale?) do
    [
      "edited #{path} (#{replaced.count} #{occurrences(replaced.count)} replaced" <>
        strategy_note(replaced.strategy) <> ")",
      stale_note(path, stale?),
      snippet(replaced)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp strategy_note(:exact), do: ""
  defp strategy_note(strategy), do: "; matched #{describe(strategy)}"

  defp describe(:line_numbers), do: "after removing the line numbers read prints"
  defp describe(:trailing_whitespace), do: "ignoring trailing whitespace"
  defp describe(:indentation), do: "ignoring indentation, and re-indented to fit"
  defp describe(:whitespace), do: "ignoring differences in whitespace"

  defp stale_note(_path, false), do: nil

  defp stale_note(path, true) do
    "Note: #{path} changed since this session last read or wrote it. The edit matched " <>
      "what is there now; read the file before relying on anything else in it."
  end

  # The edited lines with a little context, numbered as `read` numbers them.
  # The first replacement only, when there were several.
  defp snippet(replaced) do
    lines = String.split(replaced.text, "\n")
    first = max(replaced.first_line - @snippet_context, 1)
    last = min(replaced.last_line + @snippet_context, length(lines))
    shown = lines |> Enum.slice(first - 1, last - first + 1)

    {shown, cut} =
      if length(shown) > @snippet_lines,
        do: {Enum.take(shown, @snippet_lines), length(shown) - @snippet_lines},
        else: {shown, 0}

    body = Tool.number_lines(Enum.map(shown, &Tool.sanitize/1), first)
    more = if cut > 0, do: "\n… #{cut} more lines", else: ""
    also = if replaced.count > 1, do: "\n(the first of #{replaced.count} replacements)", else: ""

    body <> more <> also
  end

  defp occurrences(1), do: "occurrence"
  defp occurrences(_n), do: "occurrences"
end
