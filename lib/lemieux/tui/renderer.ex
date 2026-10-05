# Guarded as `Lemieux.TUI.ToolText` is, and for the same reason: every row a
# renderer builds goes through that module, which only exists when the
# optional terminal dependency does.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer do
    @moduledoc """
    How one tool's call and its result become rows of the transcript, and how
    to say it differently for a tool of your own.

    This module is the behaviour and the renderer of last resort at once, the
    way `Lemieux.TUI.Status` is the behaviour and the shipped row: a tool
    nobody registered a renderer for is drawn by the functions below — `Ran
    NAME`, then its first string argument, then its output — so the contract
    and the fallback cannot drift apart. The tools the screen has a verb for
    each have a renderer of their own under this namespace
    (`Lemieux.TUI.Renderer.Read`, `.Bash`, `.Edit`, `.Write`, `.Elixir`,
    `.AskUser`, `.WebSearch`), and `builtin/0` is the map of tool name to
    module they make. A host passes `renderers: %{"name" => Module}` to
    `Lemieux.TUI.start_link/1`; `registry/1` merges that over the built-ins,
    so a host can replace how `read` is drawn as easily as it can give an MCP
    tool named `server__tool` a receipt of its own. A renderer may also draw
    the card that asks for a call to be approved — `c:approval/1` — which is
    how a host with an approval policy restyles that moment too.

    ## What a renderer is given

      * The call, normalised: `%{id: id, name: name, arguments: arguments}`,
        with string-keyed arguments — however the event or the transcript
        entry spelled it. A renderer should not have to know that a live
        event carries atom keys and a resumed entry carries strings.
      * For `c:call/2`, whether the row above is already exploration, which is
        how the shipped `read` decides whether to open a new `Explored` group
        or join the one there.
      * For `c:result/3`, the result's output as printable text, its raw
        payload (`"structured_content"` is where an MCP tool's data is), and
        the theme showing — because code in a receipt is highlighted when the
        result arrives, in the palette of that moment, and never again.

    A failed call is not the renderer's to draw. Its output is shown under the
    announcement for every tool alike, before any renderer is asked, because
    the error flag is the one thing a person must never miss and a renderer
    that forgot it would hide a failed edit behind a tidy card.

    ## The invariant, and why it is enforced rather than documented

    Every row a renderer returns must be one of `Lemieux.TUI.ToolText`'s row
    shapes, and every row must belong to the call.

    The shapes are the whole of the first rule. `Lemieux.TUI.Window` pins the
    viewport by counting rows and `Lemieux.TUI.Selection` names a row by how
    many are newer than it, and both are only right if a row's height is a
    function of the row and the pane width alone; `Lemieux.TUI.RichText`
    lays each known shape out into exactly that many screen rows, and a shape
    it does not know it cannot measure at all — it would fail inside the draw
    loop, which ends the terminal rather than one receipt. `Lemieux.TUI.Blocks`
    tells the same story for the model's own blocks.

    The id is the second. `ToolText.announced?/2` is how the screen knows not
    to draw a call twice when its event is re-delivered, `ToolText.call_id/1`
    is how a result finds the rows its call announced and replaces them, and
    `output?/2` and `answer?/2` are how output streams into place beneath
    them. A row that does not carry the id is a row none of that can see. So:
    every row names this call or no call (a heading may name none, to group
    several calls the way `Explored` does), and at least one row is an
    announcement — a heading, a detail, a question or a diff — that
    `announced?/2` recognises. Output rows alone are not one; a call that
    returned only output would be announced again by every re-delivery.

    `check_rows/2` is that rule as a function, and `Lemieux.TUI.ToolText`
    runs it on everything a renderer returns, built-in or not. When it
    fails, the generic rows are drawn with one detail row naming the module
    and what was wrong with what it returned, and the screen carries on. A
    renderer is an extension, and the window is what the program is for.

    ## What a renderer may reuse

    `Lemieux.TUI.ToolText` is the toolkit the built-ins are made of, and it is
    public for that reason: `heading/4`, `detail/2`, `exploration/3`,
    `argument/3`, `one_line/1`, `summarise/1`, `question_rows/1`, and
    `edit_rows/3` and `write_rows/3` for a tool that changes a file and wants
    the same diff `edit` gets.
    """

    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.ToolText

    @typedoc "A tool call as a renderer sees it: the same shape live and on resume."
    @type call :: %{id: String.t(), name: String.t(), arguments: map()}

    @typedoc """
    A result as a renderer sees it. `output` is the tool's output as text;
    `payload` is the whole result entry, for what the text does not carry.
    """
    @type result :: %{output: String.t(), payload: map()}

    @typedoc """
    What a result does to the screen.

      * `{:replace, rows}` — the rows the call announced are removed and these
        take their place. An edit becomes its diff this way.
      * `{:output, text}` — `text` is drawn as output under the announcement,
        capped and clipped to the pane by `Lemieux.TUI.ToolText.output_rows/4`.
      * `{:answer, text}` — the person's answer to a question.
      * `:none` — the announcement already said everything worth saying.
    """
    @type outcome ::
            {:replace, [ToolText.row()]} | {:output, String.t()} | {:answer, String.t()} | :none

    @typedoc "Tool name to the module that draws it."
    @type registry :: %{String.t() => module()}

    @doc """
    The rows that announce a call, the moment the model makes it.

    `exploring?` is true when the row above is already an exploration detail,
    so a renderer that groups its calls the way `read` does can join the
    group rather than open another.
    """
    @callback call(call :: call(), exploring? :: boolean()) :: [ToolText.row()]

    @doc """
    What the call's result does to the screen. Optional: a renderer that says
    nothing about results gets `{:output, text}`, which is what an
    unregistered tool gets.
    """
    @callback result(call :: call(), result :: result(), theme :: Theme.t()) :: outcome()

    @doc """
    The rows that ask a person to decide this call, when a hook parked it.

    Optional: a renderer that says nothing about approvals gets the generic
    card, `approval/1` below. The rows go on the screen after the call's own
    announcement and come off it when the decision lands, so a card need not
    repeat what the announcement said; the shipped one names the tool, what
    it would do, and the two answers. They are held to `check_rows/2` like
    any other rows.
    """
    @callback approval(call :: call()) :: [ToolText.row()]

    @optional_callbacks result: 3, approval: 1

    @behaviour __MODULE__

    @doc """
    The renderer for a tool nobody has a verb for: `Ran NAME`, then the first
    string argument, which for most tools is the one worth reading.
    """
    @impl __MODULE__
    @spec call(call :: call(), exploring? :: boolean()) :: [ToolText.row()]
    def call(%{id: id, name: name, arguments: arguments}, _exploring?),
      do: [
        ToolText.heading(id, :other, "Ran", name)
        | ToolText.detail(id, ToolText.summarise(arguments))
      ]

    @doc "The generic result: whatever came back, as output under the heading."
    @impl __MODULE__
    @spec result(call :: call(), result :: result(), theme :: Theme.t()) :: outcome()
    def result(_call, %{output: output}, _theme), do: {:output, output}

    @doc """
    The generic approval card: `Approve NAME ARGUMENT?` and, under it, the
    two answers a person can type. `Lemieux.Conversation` reads the same
    words — `y`, `n [reason]`, `/approve`, `/deny` — so the card and the
    parser cannot disagree about what answers.
    """
    @impl __MODULE__
    @spec approval(call :: call()) :: [ToolText.row()]
    def approval(%{id: id, name: name, arguments: arguments}) do
      target = ToolText.one_line(String.trim("#{name} #{ToolText.summarise(arguments)}"))

      [
        ToolText.heading(id, :approval, "Approve", target <> "?")
        | ToolText.detail(id, "y runs it · n [reason] refuses it · /approve · /deny [reason]")
      ]
    end

    @doc "The renderers `lmx` ships, by the tool name each one draws."
    @spec builtin() :: registry()
    def builtin do
      %{
        "apply_patch" => __MODULE__.ApplyPatch,
        "ask_user" => __MODULE__.AskUser,
        "bash" => __MODULE__.Bash,
        "edit" => __MODULE__.Edit,
        "elixir" => __MODULE__.Elixir,
        "read" => __MODULE__.Read,
        "web_search" => __MODULE__.WebSearch,
        "write" => __MODULE__.Write
      }
    end

    @doc """
    The renderers a sitting draws with: `extra` merged over `builtin/0`.

    A key is a tool name exactly as the tool declares it — an MCP tool's is
    `server__tool` — and a value is a module implementing this behaviour. A
    key that matches a built-in replaces it. Every problem comes back at once.
    """
    @spec registry(extra :: %{String.t() => module()}) ::
            {:ok, registry()} | {:error, [String.t()]}
    def registry(extra) when is_map(extra) do
      problems = extra |> Enum.flat_map(&entry_problems/1) |> Enum.sort()

      case problems do
        [] -> {:ok, Map.merge(builtin(), extra)}
        problems -> {:error, problems}
      end
    end

    @doc """
    `registry/1`, raising on an entry it cannot use.

    For the host that passed the map in code, where a renderer that is not
    one is a programming error and a screen that quietly drew that tool
    plainly would hide it.
    """
    @spec registry!(extra :: %{String.t() => module()}) :: registry()
    def registry!(extra) when is_map(extra) do
      case registry(extra) do
        {:ok, registry} -> registry
        {:error, problems} -> raise ArgumentError, "renderers: " <> Enum.join(problems, "; ")
      end
    end

    defp entry_problems({name, module}) when is_binary(name) and name != "" do
      if renderer?(module),
        do: [],
        else: ["#{name}: #{inspect(module)} does not implement #{inspect(__MODULE__)}"]
    end

    defp entry_problems({name, _module}),
      do: ["#{inspect(name)}: a tool name must be a non-empty string"]

    defp renderer?(module) when is_atom(module),
      do: Code.ensure_loaded?(module) and function_exported?(module, :call, 2)

    defp renderer?(_other), do: false

    @doc "The renderer for a tool name: the registered one, or this module."
    @spec module(registry :: registry(), name :: String.t()) :: module()
    def module(registry, name) when is_map(registry) and is_binary(name),
      do: Map.get(registry, name, __MODULE__)

    @doc """
    Whether rows a renderer returned for call `id` can go on the screen.

    The invariant in the moduledoc, checked: a list, every element a row
    shape `Lemieux.TUI.ToolText.row?/1` knows, every row naming this call or
    none, and — unless the list is empty — at least one row
    `ToolText.announced?/2` recognises. The reason names what was returned,
    so the notice that replaces it says what to fix.
    """
    @spec check_rows(rows :: term(), id :: String.t()) :: :ok | {:error, String.t()}
    def check_rows(rows, id) when is_list(rows) and is_binary(id) do
      with :ok <- each_row(rows, &shape_problem/1),
           :ok <- each_row(rows, &ownership_problem(&1, id)) do
        if rows == [] or ToolText.announced?(rows, id),
          do: :ok,
          else: {:error, "returned rows none of which carries call id #{inspect(id)}"}
      end
    end

    def check_rows(rows, id) when is_binary(id),
      do: {:error, "returned #{inspect(rows)}, not a list of rows"}

    @doc """
    Whether an outcome a renderer returned for call `id` can be acted on.

    Replacement rows are held to `check_rows/2`; output and an answer must be
    text; anything else is not an outcome.
    """
    @spec check_outcome(outcome :: term(), id :: String.t()) :: :ok | {:error, String.t()}
    def check_outcome({:replace, rows}, id) when is_list(rows), do: check_rows(rows, id)
    def check_outcome({:output, text}, _id) when is_binary(text), do: :ok
    def check_outcome({:answer, text}, _id) when is_binary(text), do: :ok
    def check_outcome(:none, _id), do: :ok
    def check_outcome(outcome, _id), do: {:error, "returned #{inspect(outcome)}, not an outcome"}

    defp each_row(rows, problem) do
      Enum.find_value(rows, :ok, fn row ->
        case problem.(row) do
          nil -> nil
          reason -> {:error, reason}
        end
      end)
    end

    defp shape_problem(row) do
      unless ToolText.row?(row),
        do: "returned a row that is not a transcript row: #{inspect(row)}"
    end

    defp ownership_problem(row, id) do
      case ToolText.call_id(row) do
        ^id -> nil
        nil -> nil
        other -> "returned a row naming call #{inspect(other)}, not #{inspect(id)}"
      end
    end
  end
end
