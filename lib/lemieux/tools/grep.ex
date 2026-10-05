defmodule Lemieux.Tools.Grep do
  @moduledoc """
  Searches file contents with a regular expression, read-only and confined to
  the working directory.

  ## Why a tool when `bash` can run `rg`

  `Lemieux.Tool` sets the bar for a tool beyond the first four at "the model
  measurably cannot do the job through them", and a frontier model can. This
  one earns its place on three other counts:

    * **Authority.** It certifies itself read-only, so a delegated scout
      (`Lemieux.Subagent.Definition` admits nothing else) can search instead
      of walking a tree one `read` at a time, and a host policy can allow it
      without parsing a shell command to decide whether it writes.
    * **Bounds.** Output is capped by matches, by line length and by bytes,
      and says so. `grep -r` from a weaker model is how a session ends up with
      a minified bundle in its context.
    * **Shape.** Results come back as `path:line:text` with the line numbers
      `read` and `edit` use, relative to the working directory, with
      `.gitignore` honoured whichever backend answered.

  ## Backends

  `rg --json` through the session's environment when it is available, so a
  sandbox or container searches where the model's `bash` would. Otherwise
  the candidate files come from `Lemieux.Tools.Search.Files` (`git ls-files`,
  then a walk) and are matched here with Elixir's regular expressions, which
  agree with `rg`'s for everything but look-around and backreferences. A
  single file named by `path` is searched even if it is ignored, as `rg`
  does.

  ## What the model is told about truncation

  Everything. A search that stopped at `max_results`, a line cut at its
  character limit, output cut at the byte cap, a backend that timed out:
  each is stated in the result, because a model shown the first hundred
  matches as if they were all of them will conclude the other call sites do
  not exist.
  """

  @behaviour Lemieux.Tool

  alias Lemieux.Environment
  alias Lemieux.Tool
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.Search.Command
  alias Lemieux.Tools.Search.Files
  alias Lemieux.Tools.Search.GlobPattern
  alias Lemieux.Tools.Search.Scope

  @default_results 100
  @max_results 1_000
  @max_context 10
  @max_line_chars 300
  @max_output_bytes 30_000
  @rg_output_bytes 2_000_000
  @rg_timeout_ms 30_000
  @scan_budget_ms 20_000
  @scan_total_bytes 200_000_000
  @scan_file_bytes 5_000_000
  @binary_probe_bytes 8_000
  @modes ~w(content files_with_matches count)

  @impl Lemieux.Tool
  def name, do: "grep"

  @impl Lemieux.Tool
  def description do
    """
    Search file contents with a regular expression. Respects .gitignore and
    skips binary files. Prefer this to grep or rg in bash: results are capped,
    confined to the working directory and read-only.

    output_mode "content" (the default) returns matching lines as
    path:line:text, context lines as path-line-text, and "--" between
    separate groups. "files_with_matches" returns only the paths; "count"
    returns path:number-of-matching-lines. Line numbers are the ones read and
    edit use. When results are capped the output says so: narrow the
    pattern, path or glob rather than assuming you have seen everything.
    """
  end

  @impl Lemieux.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" =>
            "Regular expression to search for (Rust/PCRE syntax, for example \"def \\\\w+\" or " <>
              "\"foo|bar\"). Set literal to true to search for the text exactly."
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "File or directory to search, relative to the working directory. " <>
              "Defaults to the working directory."
        },
        "glob" => %{
          "type" => "string",
          "description" =>
            "Only search files matching this glob, relative to path. Without a / it matches " <>
              "at any depth (\"*.ex\", \"*.{ts,tsx}\"); with one it is anchored (\"lib/**/*.ex\")."
        },
        "output_mode" => %{
          "type" => "string",
          "enum" => @modes,
          "description" => "content (the default), files_with_matches or count."
        },
        "case_insensitive" => %{
          "type" => "boolean",
          "description" => "Match regardless of case. Defaults to false."
        },
        "literal" => %{
          "type" => "boolean",
          "description" => "Treat pattern as plain text rather than a regular expression."
        },
        "context" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => @max_context,
          "description" => "Lines of context around each match, in content mode."
        },
        "max_results" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_results,
          "description" =>
            "Most matching lines (content) or files (other modes) to return. " <>
              "Defaults to #{@default_results}."
        }
      },
      "required" => ["pattern"],
      "additionalProperties" => false
    }
  end

  # Searching cannot change what another call in the same wave sees.
  @impl Lemieux.Tool
  def parallel_safe?, do: true

  # Certified read-only, which is what lets a delegated scout carry it.
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
      runtime: %{
        concurrency: %{class: "parallel"},
        max_output_bytes: @max_output_bytes + 2_000,
        timeout_ms: 90_000
      }
    }
  end

  @impl Lemieux.Tool
  def run(%{"pattern" => pattern} = args, context) when is_binary(pattern) and pattern != "" do
    environment = Environment.from_context(context)

    with {:ok, options} <- options(args),
         {:ok, scope} <- Scope.resolve(environment, context.cwd, Map.get(args, "path")),
         {:ok, glob} <- glob(options.glob, scope) do
      search = %{
        environment: environment,
        cwd: context.cwd,
        scope: scope,
        pattern: pattern,
        glob: glob,
        options: options
      }

      search |> results() |> finish(search)
    end
  end

  def run(%{"pattern" => _pattern}, _context), do: {:error, "grep needs a non-empty pattern"}
  def run(_args, _context), do: {:error, "grep needs a pattern"}

  ## arguments

  defp options(args) do
    with {:ok, mode} <- mode(Map.get(args, "output_mode")),
         {:ok, glob} <- optional_string(args, "glob") do
      {:ok,
       %{
         mode: mode,
         glob: glob,
         case_insensitive?: Map.get(args, "case_insensitive") == true,
         literal?: Map.get(args, "literal") == true,
         context: args |> integer("context", 0) |> min(@max_context) |> max(0),
         limit: args |> integer("max_results", @default_results) |> min(@max_results) |> max(1)
       }}
    end
  end

  defp mode(nil), do: {:ok, "content"}
  defp mode(mode) when mode in @modes, do: {:ok, mode}

  defp mode(other),
    do: {:error, "output_mode must be one of #{Enum.join(@modes, ", ")}; got #{inspect(other)}"}

  defp optional_string(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      other -> {:error, "#{key} must be a string; got #{inspect(other)}"}
    end
  end

  # A glob narrows a directory search; on a single file it has nothing to do.
  defp glob(nil, _scope), do: {:ok, nil}
  defp glob(_pattern, %{kind: :file}), do: {:ok, nil}
  defp glob(pattern, _scope), do: GlobPattern.compile(pattern)

  defp integer(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_integer(value, default)
      _other -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> default
    end
  end

  ## searching

  # rg when it can run here, the native scan otherwise.
  defp results(search) do
    if Files.ripgrep_absent?(search.environment) do
      native(search)
    else
      case ripgrep(search) do
        :unavailable -> native(search)
        other -> other
      end
    end
  end

  defp ripgrep(search) do
    {directory, target} =
      case search.scope do
        %{kind: :file, relative: relative} -> {search.cwd, relative}
        %{relative: ""} -> {search.cwd, "."}
        %{relative: relative} -> {Path.join(search.cwd, relative), "."}
      end

    command = Command.join(ripgrep_arguments(search, target))

    case Command.run(search.environment, directory, command,
           timeout_ms: @rg_timeout_ms,
           max_bytes: @rg_output_bytes
         ) do
      {:ok, %{status: 127}} -> :unavailable
      {:ok, %{status: {:failed, _reason}}} -> :unavailable
      {:ok, outcome} -> ripgrep_results(search, outcome)
      {:error, _reason} -> :unavailable
    end
  end

  defp ripgrep_arguments(%{options: options} = search, target) do
    # --line-buffered keeps each JSON event in one write. The environment merges
    # stderr into stdout, and without it a warning could split an event in two
    # and make both halves unreadable.
    ~w(rg --json --line-buffered --no-config --hidden --no-require-git --sort path -g !.git) ++
      mode_arguments(options) ++
      if(options.case_insensitive?, do: ["-i"], else: ["-s"]) ++
      if(options.literal?, do: ["-F"], else: []) ++
      if(search.glob, do: ["-g", search.glob.source], else: []) ++
      ["-e", search.pattern, "--", target]
  end

  defp mode_arguments(%{mode: "files_with_matches"}), do: ["--max-count", "1"]

  defp mode_arguments(%{mode: "content", context: context}) when context > 0,
    do: ["--context", Integer.to_string(context)]

  defp mode_arguments(_options), do: []

  defp ripgrep_results(search, %{status: status, output: output}) do
    lines = String.split(output, "\n")
    # A stream cut short ends mid-event; the fragment is not a message from rg.
    lines = if status in [:truncated, :timeout], do: Enum.drop(lines, -1), else: lines

    {events, messages} = decode_events(lines)

    files =
      events
      |> fold_events()
      |> Enum.map(fn file -> {String.replace_prefix(file.path, "./", ""), file} end)
      |> Enum.filter(fn {path, _file} -> kept?(search.glob, path) end)
      |> Enum.map(fn {path, file} -> %{file | path: display_path(search.scope, path)} end)

    case {status, files, messages} do
      {2, [], [_ | _]} ->
        {:error, "grep: " <> (messages |> Enum.take(3) |> Enum.join("\n"))}

      _other ->
        {:ok,
         %{
           files: files,
           backend: "rg",
           complete?: status in [0, 1],
           notes: ripgrep_notes(status, messages)
         }}
    end
  end

  defp kept?(nil, _path), do: true
  defp kept?(glob, path), do: GlobPattern.match?(glob, path)

  defp ripgrep_notes(:timeout, _messages),
    do: ["the search timed out after #{div(@rg_timeout_ms, 1_000)}s; results are partial"]

  defp ripgrep_notes(:truncated, _messages),
    do: ["rg produced more results than grep reads; only the first part was searched"]

  defp ripgrep_notes(2, [message | _rest]),
    do: ["some files could not be searched: #{message}"]

  defp ripgrep_notes(_status, _messages), do: []

  defp decode_events(lines) do
    {events, messages} =
      Enum.reduce(lines, {[], []}, fn
        "", acc ->
          acc

        line, {events, messages} ->
          case JSON.decode(line) do
            {:ok, %{"type" => type, "data" => data}} -> {[{type, data} | events], messages}
            _other -> {events, [String.trim(line) | messages]}
          end
      end)

    {Enum.reverse(events), messages |> Enum.reverse() |> Enum.reject(&(&1 == ""))}
  end

  # Events arrive begin, match/context…, end for each file in turn.
  defp fold_events(events) do
    events
    |> Enum.reduce([], &fold_event/2)
    |> Enum.reverse()
    |> Enum.map(&%{&1 | lines: Enum.reverse(&1.lines)})
    |> Enum.reject(&(&1.lines == []))
  end

  defp fold_event({"begin", data}, files), do: [%{path: event_path(data), lines: []} | files]

  defp fold_event({kind, data}, [file | files]) when kind in ["match", "context"] do
    line = {data["line_number"], event_text(data), line_kind(kind)}
    [%{file | lines: [line | file.lines]} | files]
  end

  defp fold_event(_event, files), do: files

  defp line_kind("match"), do: :match
  defp line_kind("context"), do: :context

  defp display_path(%{kind: :file, relative: relative}, _path), do: relative
  defp display_path(scope, path), do: Scope.display(scope, path)

  defp event_path(%{"path" => %{"text" => text}}), do: text
  defp event_path(%{"path" => %{"bytes" => bytes}}), do: decode_bytes(bytes)
  defp event_path(_data), do: "(unknown path)"

  defp event_text(%{"lines" => %{"text" => text}}), do: clean_line(text)
  defp event_text(%{"lines" => %{"bytes" => bytes}}), do: bytes |> decode_bytes() |> clean_line()
  defp event_text(_data), do: ""

  defp decode_bytes(bytes) do
    case Base.decode64(bytes) do
      {:ok, decoded} -> Tool.sanitize(decoded)
      :error -> bytes
    end
  end

  ## the native scan

  defp native(search) do
    with {:ok, regex} <- regex(search.pattern, search.options),
         {:ok, candidates} <- candidates(search) do
      {:ok, scan(search, regex, candidates)}
    end
  end

  defp regex(pattern, options) do
    source = if options.literal?, do: Regex.escape(pattern), else: pattern
    flags = if options.case_insensitive?, do: "ui", else: "u"

    case Regex.compile(source, flags) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, at}} -> {:error, "grep: invalid pattern at position #{at}: #{reason}"}
    end
  end

  defp candidates(%{scope: %{kind: :file, relative: relative}}),
    do: {:ok, %{paths: [relative], backend: "file", notes: []}}

  defp candidates(search) do
    with {:ok, listing} <- Files.list(search.environment, search.cwd, search.scope.relative) do
      paths =
        listing.files
        |> Enum.filter(&kept?(search.glob, &1))
        |> Enum.map(&Scope.display(search.scope, &1))

      notes =
        if listing.complete?,
          do: [],
          else: ["the file listing was cut short, so some files were not searched"]

      {:ok, %{paths: paths, backend: Atom.to_string(listing.backend), notes: notes}}
    end
  end

  defp scan(search, regex, candidates) do
    budget = %{
      deadline: System.monotonic_time(:millisecond) + @scan_budget_ms,
      bytes: @scan_total_bytes
    }

    {state, _budget} =
      Enum.reduce_while(candidates.paths, {%{files: [], matches: 0, notes: []}, budget}, fn
        path, {state, budget} ->
          cond do
            enough?(state, search.options) ->
              {:halt, {state, budget}}

            System.monotonic_time(:millisecond) > budget.deadline or budget.bytes <= 0 ->
              note = "the search stopped at its time budget; results are partial"
              {:halt, {%{state | notes: [note | state.notes]}, budget}}

            true ->
              {:cont, scan_file(search, regex, path, state, budget)}
          end
      end)

    %{
      files: Enum.reverse(state.files),
      backend: candidates.backend,
      complete?: state.notes == [] and candidates.notes == [],
      notes: candidates.notes ++ Enum.reverse(state.notes)
    }
  end

  # One past the limit is enough to know there are more, and no further.
  defp enough?(state, %{mode: "content", limit: limit}), do: state.matches > limit
  defp enough?(state, %{limit: limit}), do: length(state.files) > limit

  defp scan_file(search, regex, path, state, budget) do
    case Environment.read_file(search.environment, search.cwd, path) do
      {:ok, contents} ->
        budget = %{budget | bytes: budget.bytes - byte_size(contents)}

        if byte_size(contents) > @scan_file_bytes or binary?(contents),
          do: {state, budget},
          else: {match_file(search, regex, path, contents, state), budget}

      {:error, _reason} ->
        {state, budget}
    end
  end

  defp binary?(contents) do
    probe = binary_part(contents, 0, min(byte_size(contents), @binary_probe_bytes))
    :binary.match(probe, <<0>>) != :nomatch
  end

  defp match_file(search, regex, path, contents, state) do
    lines =
      contents
      |> Tool.sanitize()
      |> Tool.split_lines()
      |> Enum.map(&clean_line/1)
      |> List.to_tuple()

    numbers =
      for number <- 1..tuple_size(lines)//1,
          Regex.match?(regex, elem(lines, number - 1)),
          do: number

    case numbers(numbers, state, search.options) do
      [] ->
        state

      numbers ->
        context = if search.options.mode == "content", do: search.options.context, else: 0
        file = %{path: path, lines: with_context(lines, numbers, context)}
        %{state | files: [file | state.files], matches: state.matches + length(numbers)}
    end
  end

  defp numbers(numbers, state, %{mode: "content", limit: limit}),
    do: Enum.take(numbers, max(limit + 1 - state.matches, 0))

  defp numbers([first | _rest], _state, %{mode: "files_with_matches"}), do: [first]
  defp numbers(numbers, _state, _options), do: numbers

  defp with_context(lines, numbers, context) do
    total = tuple_size(lines)
    wanted = MapSet.new(numbers)

    numbers
    |> Enum.flat_map(&Enum.to_list(max(&1 - context, 1)..min(&1 + context, total)//1))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn number ->
      kind = if MapSet.member?(wanted, number), do: :match, else: :context
      {number, elem(lines, number - 1), kind}
    end)
  end

  ## rendering

  defp finish({:error, _reason} = error, _search), do: error

  defp finish({:ok, results}, search) do
    {rows, more?} = rows(results.files, search.options)
    {kept, cut?} = fit(rows)
    shown = shown(kept, search.options)
    more? = more? or cut?
    body = Enum.map_join(kept, "\n", &row_text/1)
    summary = summary(results, search, shown, more?)
    text = if body == "", do: summary, else: body <> "\n\n" <> summary

    {:ok,
     Result.new(text,
       metadata: %{
         "backend" => results.backend,
         "matches" => shown.matches,
         "files" => shown.files,
         "truncated" => more? or not results.complete?
       }
     )}
  end

  defp rows(files, %{mode: "files_with_matches", limit: limit}) do
    {Enum.map(Enum.take(files, limit), &{:path, &1.path}), length(files) > limit}
  end

  defp rows(files, %{mode: "count", limit: limit}) do
    {Enum.map(Enum.take(files, limit), &{:count, &1.path, count(&1)}), length(files) > limit}
  end

  defp rows(files, %{mode: "content", limit: limit, context: context}) do
    {rows, taken} =
      Enum.reduce_while(files, {[], 0}, &add_file_rows(&1, &2, limit, context))

    {Enum.reverse(rows), taken < total_matches(files)}
  end

  defp add_file_rows(_file, {rows, taken}, limit, _context) when taken >= limit,
    do: {:halt, {rows, taken}}

  defp add_file_rows(file, {rows, taken}, limit, context) do
    {file_rows, file_taken} = file_rows(file, limit - taken, context)
    separator = if rows != [] and context > 0, do: [:gap], else: []
    {:cont, {file_rows ++ separator ++ rows, taken + file_taken}}
  end

  # Rows newest first. Stops at the first match past `budget`, then drops any
  # context collected for that match: it belongs to a line not being shown.
  defp file_rows(file, budget, context) do
    {rows, taken, _last, last_match} =
      Enum.reduce_while(file.lines, {[], 0, nil, nil}, &add_line(&1, &2, file.path, budget))

    {drop_orphans(rows, last_match, context), taken}
  end

  defp add_line({_number, _text, :match}, {_rows, taken, _last, _last_match} = acc, _path, budget)
       when taken >= budget,
       do: {:halt, acc}

  defp add_line({number, text, kind}, {rows, taken, last, last_match}, path, _budget) do
    rows = if last != nil and number > last + 1, do: [:gap | rows], else: rows
    rows = [{:line, path, number, kind, text} | rows]
    {taken, last_match} = if kind == :match, do: {taken + 1, number}, else: {taken, last_match}
    {:cont, {rows, taken, number, last_match}}
  end

  defp drop_orphans([{:line, _path, number, :context, _text} | rest], last_match, context)
       when is_nil(last_match) or number > last_match + context,
       do: drop_orphans(rest, last_match, context)

  defp drop_orphans([:gap | rest], last_match, context),
    do: drop_orphans(rest, last_match, context)

  defp drop_orphans(rows, _last_match, _context), do: rows

  defp count(file), do: Enum.count(file.lines, &match?({_number, _text, :match}, &1))

  defp total_matches(files), do: files |> Enum.map(&count/1) |> Enum.sum()

  # Whole rows only: a row cut at a byte offset is a line the model would read
  # as the line.
  defp fit(rows) do
    {kept, _size, cut?} =
      Enum.reduce_while(rows, {[], 0, false}, fn row, {kept, size, _cut?} ->
        size = size + byte_size(row_text(row)) + 1

        if size > @max_output_bytes,
          do: {:halt, {kept, size, true}},
          else: {:cont, {[row | kept], size, false}}
      end)

    kept = kept |> drop_trailing_gap() |> Enum.reverse()
    {kept, cut?}
  end

  defp drop_trailing_gap([:gap | rest]), do: drop_trailing_gap(rest)
  defp drop_trailing_gap(rows), do: rows

  defp shown(rows, %{mode: "count"}) do
    %{
      matches: rows |> Enum.map(fn {:count, _path, count} -> count end) |> Enum.sum(),
      files: length(rows)
    }
  end

  defp shown(rows, %{mode: "files_with_matches"}), do: %{matches: nil, files: length(rows)}

  defp shown(rows, _options) do
    lines = for {:line, path, _number, kind, _text} <- rows, do: {path, kind}

    %{
      matches: Enum.count(lines, &match?({_path, :match}, &1)),
      files: lines |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()
    }
  end

  defp row_text({:line, path, number, :match, text}),
    do: "#{path}:#{number}:#{truncate_line(text)}"

  defp row_text({:line, path, number, :context, text}),
    do: "#{path}-#{number}-#{truncate_line(text)}"

  defp row_text(:gap), do: "--"
  defp row_text({:path, path}), do: path
  defp row_text({:count, path, count}), do: "#{path}:#{count}"

  defp summary(results, search, shown, more?) do
    head =
      cond do
        shown.files == 0 ->
          glob = if search.glob, do: " (files matching #{search.glob.source})", else: ""
          "No matches for #{inspect(search.pattern)} in #{Scope.describe(search.scope)}#{glob}."

        more? ->
          "[showing #{counted(shown, search.options)}; there are more. Narrow the pattern, " <>
            "path or glob, or raise max_results.]"

        true ->
          "[#{counted(shown, search.options)}]"
      end

    Enum.join([head | Enum.map(results.notes, &"[#{&1}]")], "\n")
  end

  defp counted(shown, %{mode: "files_with_matches"}), do: plural(shown.files, "file")

  defp counted(shown, _options),
    do: "#{plural(shown.matches, "matching line")} in #{plural(shown.files, "file")}"

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp clean_line(text) do
    text
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp truncate_line(text) do
    if String.length(text) > @max_line_chars,
      do: String.slice(text, 0, @max_line_chars) <> " … [line truncated]",
      else: text
  end
end
