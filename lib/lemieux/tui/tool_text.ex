if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.ToolText do
    @moduledoc """
    Turns tool lifecycle events into compact, semantic TUI transcript rows.

    The provider event remains the source of truth. This module only decides
    what deserves screen space: reads and searches group as exploration,
    command output is capped visually (never in the durable transcript), and
    edits are reconstructed from the exact `old` and `new` arguments the model
    supplied. Syntax highlighting is computed once when the event arrives,
    outside the render loop, in the colours of the `Lemieux.TUI.Theme` that
    was showing — the same rule `Lemieux.TUI.Blocks` follows for a fenced
    block. It used to be the dark palette regardless, which on a light
    terminal painted every edit in the one place the theme did not reach.

    ## Who decides what a call looks like

    Which rows a call gets is a `Lemieux.TUI.Renderer`'s decision, looked up
    by tool name in a registry the screen carries: the built-in renderer for
    each tool this module has a verb for, a host's own merged over them, and
    the generic `Ran NAME` for everything else. This module is the toolkit
    those renderers build with and the seam that checks what they built —
    `call/4` and `result/4` hold every renderer to the row invariant stated
    in that module, and fall back to the generic rows when one breaks it.
    """

    alias ExRatatui.CodeBlock
    alias ExRatatui.Text.Span
    alias Lemieux.TUI.Diff
    alias Lemieux.TUI.Renderer
    alias Lemieux.TUI.Theme

    @output_lines 4
    @code_lines 24
    @default_width 80
    @languages %{
      ".ex" => "elixir",
      ".exs" => "elixir",
      ".go" => "go",
      ".heex" => "elixir",
      ".js" => "javascript",
      ".json" => "json",
      ".jsx" => "javascript",
      ".md" => "markdown",
      ".py" => "python",
      ".rb" => "ruby",
      ".rs" => "rust",
      ".sh" => "bash",
      ".toml" => "toml",
      ".ts" => "typescript",
      ".tsx" => "typescript",
      ".yaml" => "yaml",
      ".yml" => "yaml"
    }

    @typedoc """
    What kind of work a heading announces.

    Carried as data rather than recovered from the wording, so the renderer
    can colour by what happened without matching on English. Reading and
    searching are one tier, running a command another, changing a file
    another: a transcript where they all shared one colour was a wall nobody
    could scan for the edit in the middle of it.

    A renderer may bring a kind of its own. `Lemieux.TUI.RichText` colours a
    kind it does not know as plain text, so a new one reads rather than
    breaks, and reusing one of these borrows its colour.
    """
    @type kind :: :explore | :run | :edit | :write | :eval | :search | :other | atom()

    @typedoc "Whether a result came back as a failure."
    @type tone :: :ok | :error

    @type row ::
            {:tool_heading, String.t() | nil, kind(), String.t(), String.t()}
            | {:tool_heading, String.t() | nil, :run, String.t(), String.t(), [Span.t()]}
            | {:tool_detail, String.t(), :explore | :ordinary, String.t()}
            | {:tool_output, String.t(), :first | :rest, tone(), String.t()}
            | {:tool_question, String.t(), String.t()}
            | {:tool_option, String.t(), pos_integer(), String.t(), String.t() | nil}
            | {:tool_answer, String.t(), String.t()}
            | {:tool_code, String.t(), :add | :delete, [Span.t()]}
            | {:tool_code, String.t(), :add | :delete | :context, pos_integer() | nil, [Span.t()]}

    @doc """
    Returns the rows that announce one tool call.

    The call's renderer decides them — the one registered for its name in
    `renderers`, or `Lemieux.TUI.Renderer` itself — and what it returns is
    checked against the invariant that module states before it goes on the
    screen. Rows that fail it are replaced by the generic rows and one detail
    row saying which module returned what, so a renderer that is wrong costs
    one receipt and not the window.

    `exploring?` says the row above is already exploration, so a read can
    join the group rather than open another.

    Single-line `:run` subjects get Bash syntax spans in `theme`'s code
    palette after validation. They are computed here, once per announcement
    or replay, rather than calling the NIF on every frame. The original
    subject stays alongside them, and inline commands discard the code
    background so they read as part of the receipt rather than a fenced block.
    """
    @spec call(
            call :: map(),
            exploring? :: boolean(),
            renderers :: Renderer.registry(),
            theme :: Theme.t()
          ) ::
            [row()]
    def call(call, exploring? \\ false, renderers \\ Renderer.builtin(), theme \\ Theme.default())

    def call(call, exploring?, renderers, %Theme{} = theme)
        when is_map(call) and is_boolean(exploring?) and is_map(renderers) do
      call = normalised(call, %{})
      module = Renderer.module(renderers, call.name)
      rows = module.call(call, exploring?)

      case Renderer.check_rows(rows, call.id) do
        :ok ->
          Enum.map(rows, &command_heading(&1, theme))

        {:error, problem} ->
          Renderer.call(call, exploring?) ++ detail(call.id, plainly(module, problem))
      end
    end

    defp command_heading({:tool_heading, id, :run, verb, subject} = row, theme) do
      if String.contains?(subject, "\n") do
        row
      else
        spans =
          subject
          |> highlighted("bash", theme)
          |> List.first([])
          |> Enum.map(&%{&1 | style: %{&1.style | bg: nil}})

        {:tool_heading, id, :run, verb, subject, spans}
      end
    end

    defp command_heading(row, _theme), do: row

    @doc "Returns whether the visible tail can absorb another exploration call."
    @spec exploration_tail?(rows :: [term()]) :: boolean()
    def exploration_tail?(rows),
      do: match?({:tool_detail, _id, :explore, _text}, List.last(rows))

    @doc "Returns whether a newest-first row list starts with exploration."
    @spec exploration_head?(rows :: [term()]) :: boolean()
    def exploration_head?(rows),
      do: match?({:tool_detail, _id, :explore, _text}, List.first(rows))

    @doc """
    Formats a completed call.

    `{:replace, rows}` replaces the provisional call rows (edits and writes);
    `{:output, text}` appends or finalises output under the existing heading;
    `{:answer, text}` is the person's answer to a question; `:none` means the
    call announcement already said everything useful.

    A failure is `{:output, text}` for every tool, decided here before any
    renderer is asked — `Lemieux.TUI.Renderer` says why that is not the
    renderer's to waive. Otherwise the call's renderer decides, and its
    outcome is checked as `call/4` checks rows; one that fails becomes the
    output, with a first line saying which module returned what.

    `theme` colours the code in an edit or a write. Required rather than
    defaulted, because a default is the dark palette by another name.
    """
    @spec result(
            call :: map(),
            payload :: map(),
            theme :: Theme.t(),
            renderers :: Renderer.registry()
          ) :: Renderer.outcome()
    def result(call, payload, %Theme{} = theme, renderers \\ Renderer.builtin())
        when is_map(call) and is_map(payload) and is_map(renderers) do
      call = normalised(call, payload)
      output = printable(payload["output"])

      if payload["error"] == true do
        {:output, output}
      else
        module = Renderer.module(renderers, call.name)
        outcome = concluded(module, call, %{output: output, payload: payload}, theme)

        case Renderer.check_outcome(outcome, call.id) do
          :ok -> outcome
          {:error, problem} -> {:output, plainly(module, problem) <> "\n" <> output}
        end
      end
    end

    # A renderer that says nothing about results gets the generic one. Loaded
    # first, because `function_exported?/3` is false for a module that has
    # not been loaded yet, which in development is every module once.
    defp concluded(module, call, result, theme) do
      if Code.ensure_loaded?(module) and function_exported?(module, :result, 3),
        do: module.result(call, result, theme),
        else: Renderer.result(call, result, theme)
    end

    defp plainly(module, problem), do: "#{inspect(module)} #{problem} · drawn plainly"

    # One shape for a renderer whether the call came from a live event (atom
    # keys) or a transcript entry (strings), and whether the result payload
    # had to stand in for a call the screen never saw announced.
    defp normalised(call, payload) do
      %{
        id: value(call, :id) || payload["call_id"] || "tool",
        name: value(call, :name) || payload["name"] || "tool",
        arguments: value(call, :arguments) || payload["arguments"] || %{}
      }
    end

    @doc """
    Builds width-aware, capped rows for live or completed output.

    `tone` is `:error` when the call came back as a failure. It is the
    renderer's only way to know: a failed call's output arrives through the
    same path as a successful one, and the payload that carried the flag is
    gone by the time these rows are drawn.
    """
    @spec output_rows(
            call_id :: String.t(),
            output :: String.t(),
            width :: pos_integer(),
            tone :: tone()
          ) :: [row()]
    def output_rows(call_id, output, width \\ @default_width, tone \\ :ok)

    def output_rows(call_id, output, width, tone)
        when is_binary(call_id) and is_binary(output) and is_integer(width) and width > 0 and
               tone in [:ok, :error] do
      lines = String.split(output, "\n")
      content_width = max(width - 4, 1)
      {shown, marker} = collapsed(lines)

      rows =
        shown
        |> Enum.with_index()
        |> Enum.map(fn {line, index} ->
          position = if index == 0, do: :first, else: :rest
          {:tool_output, call_id, position, tone, String.slice(line, 0, content_width)}
        end)

      case marker || clipped_marker(lines, content_width) do
        nil -> rows
        marker -> insert_marker(rows, call_id, String.slice(marker, 0, content_width), tone)
      end
    end

    @doc "Builds the semantic rows for a question event."
    @spec question_rows(question :: map()) :: [row()]
    def question_rows(question) when is_map(question) do
      id = value(question, :call_id) || "question"
      text = value(question, :question) || ""

      text =
        if value(question, :instructions),
          do: text <> "\n" <> value(question, :instructions),
          else: text

      options = value(question, :options) || []
      fields = value(question, :fields) || []

      [
        {:tool_question, id, titled(value(question, :title), text)}
        | field_rows(id, fields) ++ option_rows(id, options)
      ]
    end

    @doc """
    The rows that ask a person to decide a call a hook parked.

    The call's renderer decides them when it implements
    `c:Lemieux.TUI.Renderer.approval/1`, and `Lemieux.TUI.Renderer.approval/1`
    — the generic card — when it does not, checked as `call/4` checks rows.
    The rows carry the call's id like any other receipt, so a host renderer
    restyles an approval the way it restyles the call; `Lemieux.TUI` keeps
    them apart from the announcement so it can take exactly them down when
    the decision lands.
    """
    @spec approval(call :: map(), renderers :: Renderer.registry()) :: [row()]
    def approval(call, renderers \\ Renderer.builtin())
        when is_map(call) and is_map(renderers) do
      call = normalised(call, %{})
      module = Renderer.module(renderers, call.name)
      rows = asked(module, call)

      case Renderer.check_rows(rows, call.id) do
        :ok -> rows
        {:error, problem} -> Renderer.approval(call) ++ detail(call.id, plainly(module, problem))
      end
    end

    # A renderer that says nothing about approvals gets the generic card.
    # Loaded first, for the reason `concluded/4` gives.
    defp asked(module, call) do
      if Code.ensure_loaded?(module) and function_exported?(module, :approval, 1),
        do: module.approval(call),
        else: Renderer.approval(call)
    end

    # An elicitation's title goes ahead of its question on the one row a
    # question has; its requested fields go under it, one line each, before
    # any options.
    defp titled(title, text) when is_binary(title) and title != "", do: "#{title} — #{text}"
    defp titled(_title, text), do: text

    defp field_rows(id, fields) when is_list(fields),
      do: Enum.flat_map(fields, &field_row(id, &1))

    defp field_rows(_id, _fields), do: []

    defp field_row(id, field) when is_map(field) do
      name = value(field, :name) || "?"
      type = value(field, :type) || "string"

      line =
        case value(field, :description) do
          description when is_binary(description) and description != "" ->
            "#{name} · #{type} — #{description}"

          _none ->
            "#{name} · #{type}"
        end

      [{:tool_detail, id, :ordinary, line}]
    end

    defp field_row(_id, _field), do: []

    @doc "Builds the semantic row for a person's answer."
    @spec answer_rows(call_id :: String.t(), answer :: String.t()) :: [row()]
    def answer_rows(call_id, answer) when is_binary(call_id) and is_binary(answer),
      do: [{:tool_answer, call_id, answer}]

    @doc "The call id associated with a row, when it belongs to one call."
    @spec call_id(row :: term()) :: String.t() | nil
    def call_id({:tool_heading, id, _kind, _verb, _subject}), do: id
    def call_id({:tool_heading, id, :run, _verb, _subject, _spans}), do: id
    def call_id({:tool_detail, id, _kind, _text}), do: id
    def call_id({:tool_output, id, _position, _tone, _text}), do: id
    def call_id({:tool_question, id, _text}), do: id
    def call_id({:tool_option, id, _index, _label, _description}), do: id
    def call_id({:tool_answer, id, _text}), do: id
    def call_id({:tool_code, id, _change, _spans}), do: id
    def call_id({:tool_code, id, _change, _number, _spans}), do: id
    def call_id(_row), do: nil

    @doc """
    Whether `rows` already announce `call_id`.

    An announcement is the part of a call that says it happened: its heading,
    its arguments, the question it asked, the diff it produced. Output and a
    person's answer are deliberately not announcements — they arrive under an
    announcement and are replaced in place, so a call whose output streamed in
    before its `{:tool_call, …}` event still needs announcing.

    This is the guard for "have I drawn this call yet", and it is not
    `call_id/1` returning a match: `ask_user` announces itself *as* the
    question, so a check that any row mentions the id would let a re-delivered
    call event draw the question a second time.
    """
    @spec announced?(rows :: [term()], call_id :: String.t()) :: boolean()
    def announced?(rows, call_id) when is_list(rows),
      do: Enum.any?(rows, &announcement?(&1, call_id))

    defp announcement?({:tool_heading, id, _kind, _verb, _subject}, id), do: true
    defp announcement?({:tool_heading, id, :run, _verb, _subject, _spans}, id), do: true
    defp announcement?({:tool_detail, id, _kind, _text}, id), do: true
    defp announcement?({:tool_question, id, _text}, id), do: true
    defp announcement?({:tool_option, id, _index, _label, _description}, id), do: true
    defp announcement?({:tool_code, id, _change, _spans}, id), do: true
    defp announcement?({:tool_code, id, _change, _number, _spans}, id), do: true
    defp announcement?(_row, _id), do: false

    @doc "Whether a row is rendered tool output."
    @spec output?(row :: term(), call_id :: String.t()) :: boolean()
    def output?({:tool_output, id, _position, _tone, _text}, id), do: true
    def output?(_row, _id), do: false

    @doc "Whether a row is the person's answer to a particular call."
    @spec answer?(row :: term(), call_id :: String.t()) :: boolean()
    def answer?({:tool_answer, id, _text}, id), do: true
    def answer?(_row, _id), do: false

    @doc """
    One more line of exploration: under a new `Explored` heading, or — when
    `exploring?` says the row above is already one — joining that group.

    The heading names no call, because it belongs to several; it is the one
    row `Lemieux.TUI.Renderer.check_rows/2` lets carry `nil`.
    """
    @spec exploration(id :: String.t(), text :: String.t(), exploring? :: boolean()) :: [row()]
    def exploration(id, text, true), do: [{:tool_detail, id, :explore, text}]

    def exploration(id, text, false),
      do: [heading(nil, :explore, "Explored"), {:tool_detail, id, :explore, text}]

    @doc "A heading row: the coloured verb a call is announced with, and its subject."
    @spec heading(
            id :: String.t() | nil,
            kind :: kind(),
            verb :: String.t(),
            subject :: String.t()
          ) :: row()
    def heading(id, kind, verb, subject \\ ""), do: {:tool_heading, id, kind, verb, subject}

    @doc """
    A detail row under a heading, as a list so it can be appended: empty for
    empty text, because a `└` with nothing after it is a row of noise.
    """
    @spec detail(id :: String.t(), text :: String.t()) :: [row()]
    def detail(_id, ""), do: []
    def detail(id, text) when is_binary(text), do: [{:tool_detail, id, :ordinary, text}]

    @doc """
    Whether `row` is one of this module's row shapes, with the fields each
    one promises.

    The check behind `Lemieux.TUI.Renderer.check_rows/2`: a row this is true
    for is one `Lemieux.TUI.RichText` lays out into an exact number of screen
    rows. Code and command spans are checked for a newline, which the draw
    loop refuses; command spans must also reproduce the subject exactly.
    """
    @spec row?(row :: term()) :: boolean()
    def row?({:tool_heading, id, kind, verb, subject})
        when (is_binary(id) or is_nil(id)) and is_atom(kind) and is_binary(verb) and
               is_binary(subject),
        do: true

    def row?({:tool_heading, id, :run, verb, subject, spans})
        when (is_binary(id) or is_nil(id)) and is_binary(verb) and is_binary(subject) and
               is_list(spans) do
      Enum.all?(spans, &span?/1) and Enum.map_join(spans, & &1.content) == subject
    end

    def row?({:tool_detail, id, kind, text})
        when is_binary(id) and is_atom(kind) and is_binary(text),
        do: true

    def row?({:tool_output, id, position, tone, text})
        when is_binary(id) and position in [:first, :rest] and tone in [:ok, :error] and
               is_binary(text),
        do: true

    def row?({:tool_question, id, text}) when is_binary(id) and is_binary(text), do: true

    def row?({:tool_option, id, index, label, description})
        when is_binary(id) and is_integer(index) and index > 0 and is_binary(label) and
               (is_binary(description) or is_nil(description)),
        do: true

    def row?({:tool_answer, id, text}) when is_binary(id) and is_binary(text), do: true

    def row?({:tool_code, id, change, spans})
        when is_binary(id) and change in [:add, :delete] and is_list(spans),
        do: Enum.all?(spans, &span?/1)

    def row?({:tool_code, id, change, number, spans})
        when is_binary(id) and change in [:add, :delete, :context] and
               (is_nil(number) or (is_integer(number) and number > 0)) and is_list(spans),
        do: Enum.all?(spans, &span?/1)

    def row?(_row), do: false

    defp span?(%Span{content: content}) when is_binary(content),
      do: not String.contains?(content, "\n")

    defp span?(_other), do: false

    defp collapsed(lines) when length(lines) <= @output_lines, do: {lines, nil}

    defp collapsed(lines) do
      hidden = length(lines) - @output_lines

      {Enum.take(lines, 2) ++ Enum.take(lines, -2),
       "… #{hidden} lines hidden · full result in transcript"}
    end

    defp clipped_marker(lines, width) do
      if Enum.any?(lines, &(String.length(&1) > width)),
        do: "… long lines clipped · full result in transcript"
    end

    defp insert_marker([first, second | rest], call_id, marker, tone) do
      [first, second, {:tool_output, call_id, :rest, tone, marker} | rest]
    end

    defp insert_marker(rows, call_id, marker, tone),
      do: rows ++ [{:tool_output, call_id, :rest, tone, marker}]

    defp option_rows(id, options) when is_list(options) do
      options
      |> Enum.with_index(1)
      |> Enum.flat_map(&option_row(id, &1))
    end

    defp option_rows(_id, _options), do: []

    defp option_row(id, {option, index}) when is_map(option) do
      description =
        [value(option, :description), value(option, :preview)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      option_row(
        id,
        index,
        value(option, :label),
        if(description == "", do: nil, else: description)
      )
    end

    defp option_row(_id, _option), do: []

    defp option_row(id, index, label, description) when is_binary(label),
      do: [{:tool_option, id, index, label, description}]

    defp option_row(_id, _index, _label, _description), do: []

    @doc """
    `Edited PATH (+added -removed)` and a unified diff of what changed,
    rebuilt from the `old` and `new` arguments.

    `output` is what `edit` returned. It carries the edited lines numbered as
    `read` numbers them, which is how the diff learns where in the file the
    change is — and gets the lines around it as context. Without them (an
    older tool, a host's own) the diff is drawn unnumbered.
    """
    @spec edit_rows(
            id :: String.t(),
            arguments :: map(),
            theme :: Theme.t(),
            output :: String.t()
          ) ::
            [row()]
    def edit_rows(id, arguments, %Theme{} = theme, output \\ "")
        when is_binary(id) and is_map(arguments) do
      path = argument(arguments, "path")
      old = argument(arguments, "old")
      new = argument(arguments, "new")

      {old_lines, new_lines, start} = located(split(old), split(new), output)
      lines = Diff.unified(old_lines, new_lines, old_start: start, new_start: start)
      {added, removed} = Diff.counts(lines)

      [heading(id, :edit, "Edited", "#{path} (+#{added} -#{removed})")] ++
        diff_rows(id, lines, language(path), theme)
    end

    @doc """
    `Wrote PATH (+lines)` and the new file's first lines, numbered, for a
    file `write` created; `Overwrote PATH` and the same for one it replaced,
    until the replaced contents are known — `diff_write_rows/5` then draws
    the change itself.
    """
    @spec write_rows(
            id :: String.t(),
            arguments :: map(),
            theme :: Theme.t(),
            output :: String.t()
          ) ::
            [row()]
    def write_rows(id, arguments, %Theme{} = theme, output \\ "")
        when is_binary(id) and is_map(arguments) do
      path = argument(arguments, "path")
      content = argument(arguments, "content")
      lines = split(content)

      case output do
        "overwrote" <> _rest ->
          [heading(id, :write, "Overwrote", "#{path} (#{length(lines)} lines)")] ++
            diff_rows(id, Diff.unified([], lines), language(path), theme)

        _created_or_unchanged ->
          if String.contains?(output, "unchanged"),
            do: [heading(id, :write, "Unchanged", path)],
            else:
              [heading(id, :write, "Wrote", "#{path} (+#{length(lines)})")] ++
                diff_rows(id, Diff.unified([], lines), language(path), theme)
      end
    end

    @doc """
    `Overwrote PATH (+added -removed)` and the diff from what the file held
    before (`previous`, from the checkpoint the tool call left) to what
    `write` put there.
    """
    @spec diff_write_rows(
            id :: String.t(),
            path :: String.t(),
            previous :: String.t(),
            content :: String.t(),
            theme :: Theme.t()
          ) :: [row()]
    def diff_write_rows(id, path, previous, content, %Theme{} = theme) do
      lines = Diff.unified(split(previous), split(content))
      {added, removed} = Diff.counts(lines)

      [heading(id, :write, "Overwrote", "#{path} (+#{added} -#{removed})")] ++
        diff_rows(id, lines, language(path), theme)
    end

    @doc """
    Rows for a computed diff, highlighted in `theme`'s code colours: each
    line numbered with where it sits in the file, a gap row for the unchanged
    lines left out, and at most #{@code_lines * 2} lines before a count of
    the rest — the whole change is in the transcript, and a screenful of diff
    is what a person scrolls past to find the next thing that happened.
    """
    @spec diff_rows(
            id :: String.t(),
            lines :: [Diff.line()],
            language :: String.t() | nil,
            theme :: Theme.t()
          ) ::
            [row()]
    def diff_rows(id, lines, language, %Theme{} = theme) do
      {shown, hidden} = Enum.split(lines, @code_lines * 2)
      spans = highlighted_lines(shown, language, theme)

      rows =
        shown
        |> Enum.zip(spans)
        |> Enum.map(fn
          {{:gap, count}, _spans} -> {:tool_detail, id, :ordinary, "⋮ #{count} unchanged lines"}
          {{change, old, new, _text}, spans} -> {:tool_code, id, change, new || old, spans}
        end)

      case length(hidden) do
        0 -> rows
        more -> rows ++ [{:tool_detail, id, :ordinary, "… +#{more} diff lines"}]
      end
    end

    # One highlight per side: a deleted line in the colours of the old text,
    # an added or context line in the new text's, so a line a highlighter
    # reads differently in context is still drawn as its side had it.
    defp highlighted_lines(lines, language, theme) do
      Enum.map(lines, fn
        {:gap, _count} -> []
        {_change, _old, _new, text} -> text |> highlighted(language, theme) |> List.first([])
      end)
    end

    # Where the edit sits: the numbered lines `edit` returned include the new
    # text, and the number of its first line is the number the old text had
    # too. The lines around it in the snippet are the diff's context.
    defp located(old_lines, new_lines, output) do
      snippet =
        output
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/^(\d+)\t(.*)$/, line, capture: :all_but_first) do
            [number, text] -> [{String.to_integer(number), text}]
            nil -> []
          end
        end)

      texts = Enum.map(snippet, &elem(&1, 1))

      case {snippet, sublist_index(texts, new_lines)} do
        {[{first, _text} | _rest], index} when is_integer(index) ->
          before = Enum.take(texts, index)
          after_new = Enum.drop(texts, index + length(new_lines))
          {before ++ old_lines ++ after_new, before ++ new_lines ++ after_new, first}

        _unknown ->
          {old_lines, new_lines, nil}
      end
    end

    defp sublist_index(_texts, []), do: nil

    defp sublist_index(texts, wanted) do
      count = length(wanted)

      Enum.find(0..max(length(texts) - count, -1)//1, fn index ->
        Enum.slice(texts, index, count) == wanted
      end)
    end

    defp split(""), do: []
    defp split(text), do: text |> String.replace_suffix("\n", "") |> String.split("\n")

    # One list of spans per line. A theme without a code theme — mono — is
    # asking for no colour, and gets one plain span per line, which is what
    # `Lemieux.TUI.Blocks` draws for a fenced block under it.
    defp highlighted(source, _language, %Theme{blocks: %{code_theme: nil}}) do
      source
      |> String.split("\n")
      |> Enum.map(fn
        "" -> []
        line -> [Span.new(line)]
      end)
    end

    defp highlighted(source, language, %Theme{blocks: %{code_theme: code_theme}}) do
      source
      |> CodeBlock.highlight(language, code_theme)
      |> Enum.map(&unterminated(&1.spans))
    end

    # The highlighter hands back each source line with its trailing newline still
    # attached to the last span. A row here *is* one line, so that terminator is not
    # content — and leaving it in is not cosmetic: `ExRatatui.Text.Span.new/2` raises
    # on a span containing a newline, inside the draw loop, so the first `write` or
    # `edit` of a session ended the terminal rather than drawing one row wrong.
    defp unterminated(spans) do
      spans
      |> Enum.map(&%{&1 | content: String.replace(&1.content, "\n", "")})
      |> Enum.reject(&(&1.content == ""))
    end

    defp language(path), do: language_of(path)

    @doc "The highlighter's language for a path, from its extension, or `nil`."
    @spec language_of(path :: String.t()) :: String.t() | nil
    def language_of(path) when is_binary(path), do: Map.get(@languages, Path.extname(path))

    @doc """
    The first string argument on one line, or `""`.

    What the generic renderer puts under `Ran NAME`: for most tools the one
    string argument is the path, the command or the query, and the one thing
    worth reading.
    """
    @spec summarise(arguments :: term()) :: String.t()
    def summarise(arguments) when is_map(arguments) do
      arguments
      |> Map.values()
      |> Enum.find("", &is_binary/1)
      |> one_line()
    end

    def summarise(_arguments), do: ""

    @doc """
    One argument as text: the string itself, anything else inspected briefly,
    and `fallback` when it is absent.
    """
    @spec argument(arguments :: map(), key :: String.t(), fallback :: String.t()) :: String.t()
    def argument(arguments, key, fallback \\ "") when is_map(arguments) and is_binary(key) do
      case Map.get(arguments, key, fallback) do
        value when is_binary(value) -> value
        value -> inspect(value, limit: 8, printable_limit: 160)
      end
    end

    @doc "The first line of `text`, and no more than 180 characters of it."
    @spec one_line(text :: String.t()) :: String.t()
    def one_line(text) when is_binary(text),
      do: text |> String.split("\n", parts: 2) |> List.first() |> String.slice(0, 180)

    defp printable(value) when is_binary(value), do: value
    defp printable(value), do: inspect(value, limit: 20, printable_limit: 2_000)

    defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
