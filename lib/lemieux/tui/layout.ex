# Guarded exactly as `Lemieux.TUI.Status` is, and for the same reason: the
# answer is rects, and the rect is the optional terminal dependency's. Unlike
# `Lemieux.TUI.Keys` nothing in a config file names a layout — it is a module,
# and `Lemieux.Extension.Profile` says why JSON never resolves one — so nothing
# needs this on a machine without the NIF.
if Code.ensure_loaded?(ExRatatui.Layout.Rect) do
  defmodule Lemieux.TUI.Layout do
    @moduledoc """
    Where the three panes go, and how to put them somewhere else.

    This module is the behaviour and the shipped arrangement at once, the way
    `Lemieux.TUI.Status` is the behaviour and the shipped row: `c:panes/2` is
    the contract, `panes/2` below is what `lmx` draws, and the two cannot
    drift. The screen asks once per frame and every consumer — the draw, the
    completion popup, paging, mouse hit-testing, drag selection — reads the
    same three rects, so a host that moves a pane moves everything that
    knew where it was.

    ## The shipped arrangement

    Transcript on top, taking whatever is left; the input box beneath it,
    growing from one to five text rows plus a border; and a status band at the
    bottom, as tall as the status line asked to be. The status band has no border of its
    own because one would cost it two more rows, and a host that replaced the
    row wants all of it. On a frame too short for all three, the input box is
    kept first, then the status band, and the transcript gets what remains,
    which may be nothing.

    ## Why rects, and not an order or a ratio

    The obvious smaller contract — "input on top" as a flag, or a split
    ratio — answers one question and forecloses the rest. A host that wants
    the input at the top, a wider status band beside the transcript rather
    than under it, a transcript of fixed height above a log of its own, or
    a margin on a wide monitor, can say each of those with three rects and
    none of them with a flag. Returning geometry rather than a preference
    also keeps the screen out of the business of guessing: it draws what it
    was given, or the shipped arrangement, and never a compromise between
    the two.

    ## What it is held to

    Four invariants, checked in `check/2` on every frame rather than trusted,
    because the failure they prevent is one pane drawn over another — an
    input box erasing the last line of the answer — and a screen that did
    that quietly on some terminal sizes would be blamed on the terminal.

      * Every rect is inside the frame.
      * No two rects share a cell. Touching is fine; so is leaving a gap.
      * The input box has at least one row and one column, or there is
        nowhere to type.
      * No rect has a negative size, which is the "transcript never
        negative" rule the shipped arithmetic keeps by construction.

    A layout that breaks one is not drawn: `arrange/3` falls back to the
    shipped arrangement and says which module broke which rule, and the
    screen puts that sentence on the transcript's lower rail until the
    layout is fixed. The panes are geometry a host computed, so a mistake
    here is a programming error, and one line on every frame is the right
    volume for it — loud enough to be fixed, quiet enough that the
    conversation is still usable meanwhile.
    """

    alias ExRatatui.Layout.Rect
    alias Lemieux.TUI.Width

    @typedoc "The terminal's size, as `ExRatatui.Frame` reports it."
    @type frame :: %{
            required(:width) => non_neg_integer(),
            required(:height) => non_neg_integer(),
            optional(atom()) => term()
          }

    @typedoc """
    What the panes need, resolved before the layout is asked.

      * `:input` — rows for the input box, `input_height/2`.
      * `:status` — rows the status line asked for, already clamped by
        `Lemieux.TUI.Status.height/2`. A host module's answer, and asked once
        per frame, so it is passed in rather than fetched again: two calls in
        one frame are two chances to disagree, and panes that disagree by a
        row either overlap or leave a hole.
    """
    @type needs :: %{input: pos_integer(), status: non_neg_integer()}

    @typedoc "The three panes, in absolute cell coordinates."
    @type panes :: %{transcript: Rect.t(), status: Rect.t(), input: Rect.t()}

    @doc """
    Where the three panes go on a frame of this size, given what they need.

    Return one rect per pane in absolute coordinates — `x: 0, y: 0` is the
    top-left cell of the terminal — under the invariants in the moduledoc.
    Asked once per frame, so it may depend on the size; it should depend on
    nothing else, because nothing else is passed.
    """
    @callback panes(frame :: frame(), needs :: needs()) :: panes()

    @behaviour __MODULE__

    # One row to type in and a border round it. Was `Lemieux.TUI`'s own
    # constant before the panes could be moved; it lives here now because the
    # layout is what spends it.
    @input_height 3
    @max_input_rows 5

    @doc "The rows the shipped arrangement gives the input box."
    @spec input_height() :: pos_integer()
    def input_height, do: @input_height

    @doc "Rows for a wrapped draft, capped so the transcript stays visible."
    @spec input_height(value :: String.t(), width :: pos_integer()) :: pos_integer()
    def input_height(value, width) when is_binary(value) and is_integer(width) and width > 0 do
      columns = max(width - 2, 1)

      rows =
        value
        |> String.split("\n")
        |> Enum.reduce_while(0, fn line, count ->
          count = count + wrapped_rows(String.graphemes(line), columns, 0)
          if count >= @max_input_rows, do: {:halt, count}, else: {:cont, count}
        end)

      min(rows, @max_input_rows) + 2
    end

    defp wrapped_rows(_chars, _columns, count) when count >= @max_input_rows, do: count
    defp wrapped_rows([], _columns, 0), do: 1
    defp wrapped_rows([], _columns, count), do: count

    # In columns, as the textarea draws: a draft of CJK measured in graphemes
    # was given half the rows it wraps to. See `Lemieux.TUI.Width`.
    defp wrapped_rows(chars, columns, count) do
      case Enum.split(chars, Width.fit(chars, columns)) do
        {_row, []} ->
          count + 1

        {row, [next | _after] = unbroken} ->
          break_at =
            (row ++ [next])
            |> Enum.with_index()
            |> Enum.reduce(nil, fn
              {" ", index}, _previous -> index
              {_char, _index}, previous -> previous
            end)

          rest =
            if is_nil(break_at),
              do: unbroken,
              else: chars |> Enum.drop(break_at + 1) |> Enum.drop_while(&(&1 == " "))

          wrapped_rows(rest, columns, count + 1)
      end
    end

    @doc """
    The layout a sitting is drawn with, given what the host asked for.

    `nil` is this module, so every caller can hold "whatever was configured"
    in one field without a second one saying whether anything was.
    """
    @spec module(configured :: module() | nil) :: module()
    def module(nil), do: __MODULE__
    def module(configured) when is_atom(configured), do: configured

    @doc """
    The shipped arrangement: transcript, input box, status band, top to bottom.

    The input box is kept before the status band and the status band before
    the transcript when the frame cannot hold all three, so the last thing
    to disappear on a tiny terminal is the place to type.
    """
    @impl __MODULE__
    @spec panes(frame :: frame(), needs :: needs()) :: panes()
    def panes(%{width: width, height: height}, %{input: input, status: status}) do
      input_height = input |> max(1) |> min(height)
      status_height = status |> max(0) |> min(height - input_height)
      transcript_height = height - input_height - status_height

      %{
        transcript: %Rect{x: 0, y: 0, width: width, height: transcript_height},
        status: %Rect{
          x: 0,
          y: transcript_height + input_height,
          width: width,
          height: status_height
        },
        input: %Rect{
          x: 0,
          y: transcript_height,
          width: width,
          height: input_height
        }
      }
    end

    @doc """
    The panes a frame is drawn with: the module's, if they keep the rules,
    else the shipped arrangement and one sentence saying why.

    The shipped module is not checked — it is the fallback, and there is
    nothing to fall back to from it.
    """
    @spec arrange(module :: module(), frame :: frame(), needs :: needs()) ::
            {:ok, panes()} | {:fallback, panes(), String.t()}
    def arrange(__MODULE__, frame, needs), do: {:ok, panes(frame, needs)}

    def arrange(module, frame, needs) when is_atom(module) do
      returned = module.panes(frame, needs)

      case check(returned, frame) do
        :ok -> {:ok, returned}
        {:error, reason} -> {:fallback, panes(frame, needs), "#{inspect(module)} #{reason}"}
      end
    end

    @panes [:transcript, :status, :input]

    @doc """
    Whether these panes can be drawn on this frame: the invariants in the
    moduledoc, as a function. The reason names the pane and the rule, so the
    notice that replaces the layout says what to fix.
    """
    @spec check(panes :: term(), frame :: frame()) :: :ok | {:error, String.t()}
    def check(panes, frame) when is_map(panes) and not is_struct(panes) do
      with :ok <- shape(panes),
           :ok <- each(@panes, &inside(&1, Map.fetch!(panes, &1), frame)),
           :ok <- typeable(panes.input) do
        disjoint(panes)
      end
    end

    def check(panes, _frame), do: {:error, "returned #{inspect(panes)}, not three rects"}

    defp shape(panes) do
      cond do
        Enum.sort(Map.keys(panes)) != Enum.sort(@panes) ->
          {:error,
           "returned #{inspect(panes)}, not three rects named transcript, status and input"}

        name = Enum.find(@panes, &(not rect?(Map.fetch!(panes, &1)))) ->
          {:error, "returned #{inspect(Map.fetch!(panes, name))} for the #{name}, not a rect"}

        true ->
          :ok
      end
    end

    defp rect?(%Rect{x: x, y: y, width: width, height: height}),
      do: is_integer(x) and is_integer(y) and is_integer(width) and is_integer(height)

    defp rect?(_other), do: false

    defp inside(name, %Rect{} = rect, %{width: width, height: height}) do
      cond do
        rect.width < 0 or rect.height < 0 ->
          {:error, "gave the #{name} a negative size (#{describe(rect)})"}

        rect.x < 0 or rect.y < 0 or rect.x + rect.width > width or rect.y + rect.height > height ->
          {:error, "put the #{name} outside the #{width}×#{height} frame (#{describe(rect)})"}

        true ->
          :ok
      end
    end

    defp typeable(%Rect{width: width, height: height}) when width < 1 or height < 1,
      do: {:error, "left the input box no row to type in (#{width}×#{height})"}

    defp typeable(%Rect{}), do: :ok

    # Every pair once, named in the order the shipped arrangement stacks them.
    # A rect with no area cannot share a cell with anything, which is what
    # lets the shipped arrangement give the status band zero rows on a tiny
    # frame.
    defp disjoint(panes) do
      indexed = Enum.with_index(@panes)
      pairs = for {a, i} <- indexed, {b, j} <- indexed, i < j, do: {a, b}

      each(pairs, fn {a, b} ->
        if overlap?(Map.fetch!(panes, a), Map.fetch!(panes, b)),
          do: {:error, "let the #{a} and the #{b} overlap"},
          else: :ok
      end)
    end

    defp overlap?(%Rect{} = a, %Rect{} = b) do
      a.width > 0 and a.height > 0 and b.width > 0 and b.height > 0 and
        a.x < b.x + b.width and b.x < a.x + a.width and
        a.y < b.y + b.height and b.y < a.y + a.height
    end

    defp each(items, problem) do
      Enum.find_value(items, :ok, fn item ->
        case problem.(item) do
          :ok -> nil
          {:error, _reason} = error -> error
        end
      end)
    end

    defp describe(%Rect{x: x, y: y, width: width, height: height}),
      do: "x: #{x}, y: #{y}, width: #{width}, height: #{height}"
  end
end
