defmodule Lemieux.Tools.Read do
  @moduledoc """
  Reads a file with line numbers, or lists one directory level.

  ## Why the numbers

  The numbers are not decoration; they are how `Lemieux.Tools.Edit` and the
  model agree about where something is. A model that has read a numbered file
  can say "the third occurrence, at line 240"; one that has read a flat blob
  can only say "the bit that looks like this", and then guesses.

  They are the file's own line numbers, not the window's, which is why
  `offset` shifts them. A window renumbered from one is a window that makes
  the model edit the wrong place.

  ## The caps

  Three of them, doing different jobs. `limit` bounds how many *lines* the
  model asked for. The byte cap bounds what a session's context can survive,
  and applies whether or not the model asked for it — a 40MB minified bundle
  read in full is a session over before it started. A single line longer than
  2,000 bytes is shown up to that and marked, because one minified line is
  otherwise the whole budget.

  The byte cap stops **at a line boundary** and says where to continue:
  `continue with offset=N`. It used to keep the head and the tail of the
  window and cut the middle, which is right for a build log and wrong for a
  file — the model was shown line 1 and line 1,800 with a gap between, and had
  no way to ask for the gap except by guessing an offset. Every cap announces
  itself in the output, because the failure that matters is a model
  concluding the rest of a file does not exist.

  ## Streaming, binaries and line endings

  The file is read as a stream of chunks (`Lemieux.Environment.stream_file/3`)
  rather than into memory whole, so a multi-gigabyte log costs the window it
  shows. The rest is still scanned, to say how many lines there are, up to
  128 MB past the window; beyond that the total is
  reported as unknown rather than paid for.

  A NUL byte in the first 8 KB marks a binary file, which is
  reported as one instead of being decoded into thousands of replacement
  characters. A carriage return before each newline is not shown — `edit`
  matches either way and keeps the file's own line endings — and the output
  says the file uses them.

  Reading a whole file records its fingerprint for the session (see
  `Lemieux.Tool.FileState`), which is what allows a later `write` to replace
  it.

  ## Images and PDFs

  A PNG, JPEG, GIF or WebP file is returned as an image attachment
  (`Lemieux.Tool.Attachment`) and a PDF as a document — when the session's
  model is known to accept that input (`input_modalities` in the tool
  context). The bytes decide, not the name: a `.png` that is really text is
  read as text. Otherwise the result says in words what the file is and why
  it is not shown, since an image sent to a model that cannot read it is a
  provider refusal on every later request that still carries it; unknown
  capability counts as not accepting. A PDF that cannot be attached is
  converted with `pdftotext` when the environment has it, and read as
  numbered text. Files over `Lemieux.Tool.Attachment.max_bytes/1` are
  described, not attached.
  """

  @behaviour Lemieux.Tool

  alias Lemieux.Environment
  alias Lemieux.Tool
  alias Lemieux.Tool.Attachment
  alias Lemieux.Tool.FileState
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.Search.Command

  @max_bytes 60_000
  @default_limit 2_000
  @max_line_bytes 2_000
  @sniff_bytes 8_192
  @scan_bytes 128_000_000

  @impl Lemieux.Tool
  def name, do: "read"

  @impl Lemieux.Tool
  def description do
    """
    Read a file or list a directory from the filesystem. File contents and
    directory entries are numbered; directories end in `/` and symlinks end in
    `@`.

    Paths are relative to the working directory and cannot escape it; an
    absolute path inside it works too. Use offset and limit to read a window of
    a large file or directory. Directory listings are one level deep. Long
    output stops at a line boundary and says which offset to continue from.
    Images (PNG, JPEG, GIF, WebP) and PDFs are attached for you to look at
    when you can view them; otherwise the result says what the file is. Other
    binary files are reported rather than shown.
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
        "offset" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "First line to read, 1-based. Defaults to the start of the file."
        },
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "How many lines to read. Defaults to #{@default_limit}."
        }
      },
      "required" => ["path"],
      "additionalProperties" => false
    }
  end

  # Reading a file cannot change what another call in the same wave sees. It is
  # scheduled after the writers rather than alongside them — see
  # `Lemieux.Session`'s `run_tools/2` — so this only says it is happy to share
  # with the other readers, not that it may overlap an edit.
  @impl Lemieux.Tool
  def parallel_safe?, do: true

  # The only one of the four that is. It is what an agent answering another
  # agent's question is allowed to do — see `c:Lemieux.Tool.read_only?/0`.
  @impl Lemieux.Tool
  def read_only?, do: true

  @impl Lemieux.Tool
  def metadata do
    %{
      effects: %{
        class: "read",
        resource_types: ["file", "directory"],
        idempotent: true,
        retryable: true
      },
      policy: %{approval: "never"},
      runtime: %{concurrency: %{class: "parallel"}, max_output_bytes: @max_bytes}
    }
  end

  @impl Lemieux.Tool
  def run(%{"path" => path} = args, context) when is_binary(path) do
    case Environment.stream_file(Environment.from_context(context), context.cwd, path) do
      {:ok, chunks} -> read_as(Attachment.kind_of(path), chunks, args, path, context)
      {:error, reason} -> unreadable(reason, args, path, context)
    end
  end

  def run(_args, _context), do: {:error, "read needs a path"}

  defp unreadable(:outside_worktree, _args, path, _context),
    do: {:error, "#{path}: is outside the working directory"}

  defp unreadable(:enoent, _args, path, _context), do: {:error, "#{path}: no such file"}
  defp unreadable(:eisdir, args, path, context), do: list_directory(args, context, path)

  defp unreadable(reason, _args, path, _context),
    do: {:error, "#{path}: #{:file.format_error(reason)}"}

  defp read_as(nil, chunks, args, path, context), do: {:ok, read(chunks, args, path, context)}

  defp read_as({kind, _claimed}, chunks, args, path, context) do
    limit = Attachment.max_bytes(kind)
    {data, size, hash} = gather(chunks, limit)
    bytes = IO.iodata_to_binary(data)

    if matches?(kind, Attachment.sniff(bytes)) do
      if hash, do: FileState.record(context, path, hash |> :crypto.hash_final() |> hex())
      media(kind, bytes, %{size: size, whole?: hash != nil, limit: limit}, args, path, context)
    else
      # Named like an image or a PDF, but the bytes say otherwise: read it as
      # what it is.
      reread(args, path, context)
    end
  end

  # Up to one byte past `limit`, which is how an oversized file is known to be
  # one without being read whole. The hash is `nil` once that happens: a file
  # not read to its end has no fingerprint.
  defp gather(chunks, limit) do
    Enum.reduce_while(chunks, {[], 0, :crypto.hash_init(:sha256)}, fn chunk, {data, size, hash} ->
      size = size + byte_size(chunk)

      if size > limit,
        do: {:halt, {[data, chunk], size, nil}},
        else: {:cont, {[data, chunk], size, :crypto.hash_update(hash, chunk)}}
    end)
  end

  defp matches?(:image, sniffed), do: is_binary(sniffed) and Attachment.image_type?(sniffed)
  defp matches?(:document, sniffed), do: sniffed == "application/pdf"

  defp reread(args, path, context) do
    case Environment.stream_file(Environment.from_context(context), context.cwd, path) do
      {:ok, chunks} -> {:ok, read(chunks, args, path, context)}
      {:error, reason} -> unreadable(reason, args, path, context)
    end
  end

  defp media(kind, bytes, %{whole?: false} = file, args, path, context),
    do: not_attached(kind, bytes, {:too_large, file}, args, path, context)

  defp media(kind, bytes, _file, args, path, context) do
    attachment = Attachment.new(kind, Attachment.sniff(bytes), bytes, path: path)
    modalities = Map.get(context, :input_modalities, :unknown)

    if Attachment.accepted?(attachment, modalities) do
      {:ok, Result.new(attached_text(kind, attachment, path), attachments: [attachment])}
    else
      not_attached(kind, bytes, {:not_accepted, modalities, attachment}, args, path, context)
    end
  end

  defp attached_text(:image, attachment, path),
    do: "#{path}: image (#{Attachment.describe(attachment)}), attached for you to view."

  defp attached_text(:document, attachment, path),
    do: "#{path}: PDF document (#{Attachment.describe(attachment)}), attached for you to read."

  defp not_attached(:image, _bytes, why, _args, path, _context) do
    {:ok, "#{path} is an image (#{what(why)}). It is not shown because #{because(:image, why)}."}
  end

  defp not_attached(:document, _bytes, why, args, path, context) do
    case pdf_text(path, context) do
      {:ok, text} ->
        {:ok,
         "[text extracted from #{path} with pdftotext; the PDF itself is not attached because " <>
           "#{because(:document, why)}]\n\n" <> read([text], args, path, context, false)}

      :unavailable ->
        {:ok,
         "#{path} is a PDF (#{what(why)}). It is not attached because " <>
           "#{because(:document, why)}, and pdftotext is not available here to extract its " <>
           "text; if another PDF tool is installed, bash can run it."}
    end
  end

  defp what({:not_accepted, _modalities, attachment}), do: Attachment.describe(attachment)
  defp what({:too_large, %{limit: limit}}), do: "over #{Attachment.human_size(limit)}"

  defp because(:image, {:too_large, %{limit: limit}}),
    do: "images over #{Attachment.human_size(limit)} are too large to attach"

  defp because(:document, {:too_large, %{limit: limit}}),
    do: "PDFs over #{Attachment.human_size(limit)} are too large to attach"

  defp because(kind, {:not_accepted, :unknown, _attachment}),
    do: "this session does not know whether its model can #{verb(kind)}"

  defp because(kind, {:not_accepted, _modalities, _attachment}),
    do: "the current model cannot #{verb(kind)}"

  defp verb(:image), do: "view images"
  defp verb(:document), do: "read PDFs"

  # Through the environment, so a sandbox or a container runs the tool where
  # the file is. 127 is the shell saying the program does not exist.
  defp pdf_text(path, context) do
    command = Command.join(["pdftotext", "-layout", "-q", "-enc", "UTF-8", path, "-"])
    environment = Environment.from_context(context)

    case Command.run(environment, context.cwd, command, max_bytes: 8_000_000) do
      {:ok, %{status: 0, output: text}} when text != "" -> {:ok, text}
      _missing_or_failed -> :unavailable
    end
  end

  defp read(chunks, args, path, context, record? \\ true) do
    offset = max(integer(args, "offset", 1), 1)
    limit = max(integer(args, "limit", @default_limit), 1)

    state =
      Enum.reduce_while(chunks, scan(offset, limit), fn chunk, state ->
        state |> consume(chunk) |> continue?()
      end)

    state = finish(state)

    if record? and state.complete? and not state.binary?,
      do: FileState.record(context, path, state.hash |> :crypto.hash_final() |> hex())

    render(state, path)
  end

  defp scan(offset, limit) do
    %{
      offset: offset,
      last: offset + limit - 1,
      bytes: 0,
      line: 0,
      partial: [],
      partial_bytes: 0,
      window: [],
      window_bytes: 0,
      cut_at: nil,
      crlf?: false,
      binary?: false,
      complete?: true,
      past_window: 0,
      hash: :crypto.hash_init(:sha256)
    }
  end

  defp consume(state, chunk) do
    state = sniff(state, chunk)
    state = %{state | bytes: state.bytes + byte_size(chunk)}
    state = %{state | hash: :crypto.hash_update(state.hash, chunk)}
    state = if state.binary?, do: state, else: lines(state, chunk)

    if window_done?(state),
      do: %{state | past_window: state.past_window + byte_size(chunk)},
      else: state
  end

  # Only the first few kilobytes are sniffed, as `git` and `file` do: a NUL
  # there is a binary file, and one later on is a text file with a NUL in it.
  defp sniff(%{bytes: bytes} = state, _chunk) when bytes >= @sniff_bytes, do: state

  defp sniff(state, chunk) do
    region = binary_part(chunk, 0, min(byte_size(chunk), @sniff_bytes - state.bytes))
    %{state | binary?: :binary.match(region, <<0>>) != :nomatch}
  end

  defp continue?(%{binary?: true} = state), do: {:halt, %{state | complete?: false}}

  defp continue?(%{past_window: past} = state) when past > @scan_bytes,
    do: {:halt, %{state | complete?: false}}

  defp continue?(state), do: {:cont, state}

  defp window_done?(state), do: state.cut_at != nil or state.line >= state.last

  # Splits a chunk into lines, carrying the unfinished last one into the next
  # chunk. The carried line is held only up to the display cap: a 100MB line
  # with no newline would otherwise be 100MB of memory to show 2KB of it.
  defp lines(state, chunk) do
    [first | rest] = :binary.split(chunk, "\n", [:global])
    state = extend(state, first)

    Enum.reduce(rest, state, fn piece, state ->
      state |> complete_line() |> extend(piece)
    end)
  end

  # One byte more than the cap is held, which is how `display/2` knows a line
  # was longer without holding it.
  defp extend(state, piece) do
    room = @max_line_bytes + 1 - IO.iodata_length(state.partial)

    partial =
      if room > 0,
        do: [state.partial, binary_part(piece, 0, min(room, byte_size(piece)))],
        else: state.partial

    %{state | partial: partial, partial_bytes: state.partial_bytes + byte_size(piece)}
  end

  defp complete_line(state) do
    line = state.line + 1
    length = state.partial_bytes
    {text, crlf?} = state.partial |> IO.iodata_to_binary() |> carriage_return(length)
    state = %{state | line: line, partial: [], partial_bytes: 0, crlf?: state.crlf? or crlf?}

    if line >= state.offset and line <= state.last and is_nil(state.cut_at),
      do: show(state, line, display(text, if(crlf?, do: length - 1, else: length))),
      else: state
  end

  # Only a line held whole can have its `\r` seen and removed; the end of a
  # line longer than the cap is never shown, so its `\r` does not matter.
  defp carriage_return(text, length) when byte_size(text) == length do
    if String.ends_with?(text, "\r"),
      do: {binary_part(text, 0, byte_size(text) - 1), true},
      else: {text, false}
  end

  defp carriage_return(text, _length), do: {text, false}

  # The first line of a window is always shown, however long: a window that
  # stopped before its first line would ask the model to continue from where it
  # already is.
  defp show(state, line, text) do
    rendered = "#{line}\t#{text}"
    size = byte_size(rendered) + 1

    if state.window_bytes + size > @max_bytes and state.window != [],
      do: %{state | cut_at: line},
      else: %{state | window: [rendered | state.window], window_bytes: state.window_bytes + size}
  end

  defp finish(%{binary?: true} = state), do: state
  defp finish(%{partial_bytes: 0} = state), do: state
  defp finish(state), do: complete_line(state)

  defp display(text, length) when length <= @max_line_bytes, do: Tool.sanitize(text)

  defp display(text, length) do
    shown = text |> binary_part(0, min(byte_size(text), @max_line_bytes)) |> Tool.sanitize()
    shown <> " … [a #{length}-byte line, cut at #{@max_line_bytes}]"
  end

  defp render(%{binary?: true}, path) do
    "#{path} is a binary file (it contains NUL bytes), so it is not shown as text. " <>
      "Use bash to inspect it — `file`, or `xxd` piped to `head`."
  end

  defp render(%{line: 0}, path), do: "#{path} is empty (0 bytes)"

  defp render(%{window: []} = state, path) do
    "#{path} has #{total(state)}; offset #{state.offset} is past the end"
  end

  defp render(state, path) do
    body = state.window |> Enum.reverse() |> Enum.join("\n")

    [body, window_note(state, path), crlf_note(state)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp window_note(%{cut_at: cut_at} = state, _path) when is_integer(cut_at) do
    "[output stopped before line #{cut_at} to stay under #{@max_bytes} bytes; " <>
      "continue with offset=#{cut_at}#{of_total(state)}]"
  end

  defp window_note(state, _path) do
    shown = min(state.last, state.line)

    cond do
      not state.complete? ->
        "[showing lines #{state.offset}-#{shown}; the file continues, and is too large " <>
          "to count its lines]"

      state.offset > 1 or state.last < state.line ->
        "[showing lines #{state.offset}-#{shown} of #{state.line}]"

      true ->
        nil
    end
  end

  defp of_total(%{complete?: true, line: line}), do: "; the file has #{line} lines"
  defp of_total(_state), do: ""

  defp total(%{complete?: true, line: 1}), do: "1 line"
  defp total(%{complete?: true, line: line}), do: "#{line} lines"
  defp total(%{line: line}), do: "more than #{line} lines"

  defp crlf_note(%{crlf?: true}),
    do: "[the file uses CRLF (\\r\\n) line endings, not shown; edit keeps them]"

  defp crlf_note(_state), do: nil

  defp hex(digest), do: Base.encode16(digest, case: :lower)

  defp list_directory(args, context, path) do
    environment = Environment.from_context(context)

    case Environment.list_dir(environment, context.cwd, path) do
      {:ok, entries} -> {:ok, render_directory(entries, args, path)}
      {:error, :unsupported} -> {:error, "#{path}: directory listing is not supported here"}
      {:error, :outside_worktree} -> {:error, "#{path}: is outside the working directory"}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp render_directory([], _args, path), do: "#{path} is an empty directory"

  defp render_directory(entries, args, path) do
    total = length(entries)
    offset = max(integer(args, "offset", 1), 1)
    limit = max(integer(args, "limit", @default_limit), 1)

    case entries |> Enum.drop(offset - 1) |> Enum.take(limit) do
      [] ->
        "#{path} has #{total} entries; offset #{offset} is past the end"

      window ->
        window
        |> Enum.map(&directory_name/1)
        |> Tool.number_lines(offset)
        |> Tool.truncate(@max_bytes)
        |> note_window(offset, limit, total)
    end
  end

  defp directory_name(%{name: name, type: :directory}), do: name <> "/"
  defp directory_name(%{name: name, type: :symlink}), do: name <> "@"
  defp directory_name(%{name: name}), do: name

  defp note_window(rendered, offset, limit, total) do
    last = offset + limit - 1

    if offset > 1 or last < total do
      shown = min(last, total)

      rendered <> "\n\n[showing lines #{offset}-#{shown} of #{total}]"
    else
      rendered
    end
  end

  defp integer(args, key, default) do
    case Map.get(args, key, default) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _other -> default
    end
  rescue
    # The model wrote something that is not a number where a number goes.
    # Reading the file with the default window is a better answer than an
    # error that teaches it nothing.
    ArgumentError -> default
  end
end
