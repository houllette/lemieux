# Unguarded, unlike `Lemieux.TUI` itself, for the reason `Lemieux.TUI.Processing`
# and `Lemieux.TUI.Theme` are: this is a table of key names to actions, with no
# widget and no NIF in it. `Lemieux.CLI.Config` validates a configured table at
# load, on a machine that may never have had the optional terminal dependency
# installed, and cannot reach a module that only exists when it does. The
# callback therefore takes a map with `:code` and `:modifiers` rather than naming
# `ExRatatui.Event.Key` — the struct is one — so nothing here refers to a module
# that may be absent.
defmodule Lemieux.TUI.Keys do
  @moduledoc """
  Which key does what on the screen, and how to change it.

  This module is the behaviour and the shipped table at once, the way
  `Lemieux.TUI.Status` is the behaviour and the shipped row: `c:action/1` is
  the contract, `action/1` below is what `lmx` ships, and the two cannot
  drift. The screen asks it one question per key event — which action, or
  `:forward` — and then does the action. It never asks anything else, which
  is what makes a key map small enough to be data.

  ## The actions

  A closed vocabulary, named for what each does to the screen rather than
  for the key it sits on, because the key is the part that changes:

    * `:interrupt` — cancel the turn if one is running; otherwise arm exit,
      and leave if pressed again inside the window. `ctrl-c`.
    * `:submit` — take the highlighted completion if the menu is open,
      otherwise send what is in the input box. `enter`.
    * `:previous` and `:next` — move through the completion menu when it is
      open, otherwise through input history. In a multiline draft, plain Up
      and Down move the caret; Alt+Up and Alt+Down still browse history.
    * `:scroll_up` and `:scroll_down` — scroll the transcript a few rows.
      `shift-up` and `shift-down`.
    * `:page_up` and `:page_down` — scroll the transcript a screenful less
      two rows. `page_up` and `page_down`.
    * `:complete` — take the highlighted completion, or the follow-up hint
      when the box is empty; while an agent is working, queue a nonempty draft
      or slash command
      for the next turn. `tab`.
    * `:select_queued` — select a numbered queued message. `alt-1` to `alt-9`.
    * `:revise_queued` — return the selected queued message to the editor. `alt-e`.
    * `:unstage_queued` — discard the selected queued message. `alt-u`.
    * `:revoke_steer` — take back the steer waiting for the next model
      request, as `/unsteer` does; with none waiting the key is the
      editor's. `alt-z`, which is Option-Z wherever the Option key sends
      Alt. Cmd-Z does the same on a terminal that reports the Command key,
      which no table can bind (see the grammar).
    * `:dismiss` — clear the input box, the completion menu, the history
      position and the selection, and close the notice box. `esc`.
    * `:newline` — insert a line break without sending. `ctrl-j`, for the
      terminals that cannot tell `shift-enter` from `enter`; a line ending in
      a backslash does the same on `enter`.
    * `:pager` — read the last tool output in full, with its scrollback.
      `ctrl-o`. See `Lemieux.TUI.Pager`.
    * `:history_search` — search every input remembered, this sitting's and
      earlier ones', as a shell's reverse search does. `ctrl-r`.
    * `:external_editor` — write the input in `$VISUAL` or `$EDITOR`.
      `ctrl-g`. See `Lemieux.TUI.ExternalEditor`.
    * `:paste_image` — attach the image on the clipboard. `ctrl-v`, since a
      terminal's own paste carries text only. See `Lemieux.TUI.ImagePaste`.
    * `:cycle_mode` — step the permission mode, when the host enabled
      permissions: ask, accept edits, auto, read-only. `shift-tab`. With
      the model picker open it steps the picker's tabs instead.
    * `:toggle_notifications` — turn the finished/waiting notifications off
      or back on for the sitting. `alt-n`.

  `:forward` is not an action: it is the answer for every key the table does
  not claim, and it hands the key to the input box untouched. The editing
  vocabulary — cursor, word motion, kill and yank, selection with shift — is
  whatever the underlying editor supports, and this table deliberately knows
  nothing about it. A host that wants a key back for the editor binds it to
  `forward`.

  ## The grammar

  A key is described as its `ex_ratatui` code with modifiers in front, joined
  by `-`: `enter`, `ctrl-c`, `shift-up`, `ctrl-shift-page_up`, `f5`, `a`.
  The codes are the library's lower-case ones — `enter`, `esc`, `tab`,
  `back_tab`, `backspace`, `delete`, `insert`, `up`, `down`, `left`, `right`,
  `home`, `end`, `page_up`, `page_down`, `f1` to `f12` — or a single
  character; `space` names the space bar, since a bare space is unreadable
  in a file, and a trailing `-` is the hyphen key, so `ctrl--` is ctrl and
  hyphen. The modifiers are `ctrl`, `alt` and `shift`, in any order and any
  case: `ctrl-shift-up` and `Shift-Ctrl-Up` are one binding, and `to_map/1`
  writes it as `ctrl-shift-up`.

  A binding names its modifier set exactly. `enter` is not `shift-enter`,
  which is what lets `shift-up` mean something other than `up`. A key that
  arrives with a modifier the grammar cannot name — `super`, `meta`,
  `hyper` — is looked up without it, because no table could have bound it
  and the key it arrived on should still find its binding.

  ## The data form, and what it may not do

  `from_map/1` reads a string-keyed map of key description to action name,
  merges it over the shipped table key by key — a key the map does not
  mention keeps its default — and names every problem at once, so a file
  with three mistakes costs one edit. `"keys"` in `~/.lmx/config.json` is
  that map; `Lemieux.CLI.Config` checks it at load, and `Lemieux.TUI` takes
  the result as `keys:`. `to_map/1` writes the effective table back.

  Two invariants, both enforced there rather than described here. A key
  cannot do two things: the table is a map, so one description cannot, but
  two spellings of the same key can, and a map that binds `ctrl-shift-up`
  and `shift-ctrl-up` to different actions is refused rather than resolved
  by whichever was read last. And `:interrupt` must remain bound to
  something: it is the only way out of a running turn and the way out of
  the program, and a map that took `ctrl-c` for something else without
  giving `interrupt` another key would leave a person with the terminal's
  kill signal as their exit. A module key map is trusted with both, because
  it is code and its author can read this.
  """

  @actions [
    :interrupt,
    :submit,
    :previous,
    :next,
    :scroll_up,
    :scroll_down,
    :page_up,
    :page_down,
    :complete,
    :select_queued,
    :revise_queued,
    :unstage_queued,
    :revoke_steer,
    :dismiss,
    :newline,
    :pager,
    :history_search,
    :external_editor,
    :paste_image,
    :cycle_mode,
    :toggle_notifications
  ]

  @typedoc "What a key does to the screen. The moduledoc says what each means."
  @type action ::
          :interrupt
          | :submit
          | :previous
          | :next
          | :scroll_up
          | :scroll_down
          | :page_up
          | :page_down
          | :complete
          | :select_queued
          | :revise_queued
          | :unstage_queued
          | :revoke_steer
          | :dismiss
          | :newline
          | :pager
          | :history_search
          | :external_editor
          | :paste_image
          | :cycle_mode
          | :toggle_notifications

  @typedoc """
  A key event as the table sees it: the code and the modifiers held.

  A plain map type rather than the `ExRatatui.Event.Key` struct, which matches it,
  so this module never names a struct that only exists when the optional
  terminal dependency does.
  """
  @type key :: %{
          required(:code) => String.t() | nil,
          required(:modifiers) => [String.t()],
          optional(atom()) => term()
        }

  @typedoc """
  One key, normalised: its modifiers sorted, and its code lower-cased.

  The shape both the table and an event are reduced to before they meet, so
  `ctrl-shift-up`, `shift-ctrl-up` and an event carrying
  `["shift", "ctrl"]` are one key.
  """
  @type binding :: {[String.t()], String.t()}

  @typedoc "A key map as data: every binding in force, defaults included."
  @type t :: %__MODULE__{bindings: %{binding() => action() | :forward}}

  @doc """
  What this key does: an action, or `:forward` to hand it to the editor.

  Asked once per key event with the event's code and modifiers. Return an
  atom from `actions/0` or `:forward`; anything else is forwarded, and the
  screen says so once in the transcript.
  """
  @callback action(key :: key()) :: action() | :forward

  @behaviour __MODULE__

  @modifiers ~w(alt ctrl shift)

  # `ExRatatui.Event.Key`'s table of special keys, which is the list a
  # description is checked against so that `escape` is refused rather than
  # bound to a key that never arrives.
  @named_keys ~w(enter esc tab back_tab backspace delete insert up down left right home end
                 page_up page_down caps_lock scroll_lock num_lock print_screen pause menu
                 keypad_begin) ++ Enum.map(1..12, &"f#{&1}")

  @defaults %{
    {["ctrl"], "c"} => :interrupt,
    {[], "enter"} => :submit,
    {[], "up"} => :previous,
    {[], "down"} => :next,
    {["alt"], "up"} => :previous,
    {["alt"], "down"} => :next,
    {["shift"], "up"} => :scroll_up,
    {["shift"], "down"} => :scroll_down,
    {[], "page_up"} => :page_up,
    {[], "page_down"} => :page_down,
    {[], "tab"} => :complete,
    {["alt"], "1"} => :select_queued,
    {["alt"], "2"} => :select_queued,
    {["alt"], "3"} => :select_queued,
    {["alt"], "4"} => :select_queued,
    {["alt"], "5"} => :select_queued,
    {["alt"], "6"} => :select_queued,
    {["alt"], "7"} => :select_queued,
    {["alt"], "8"} => :select_queued,
    {["alt"], "9"} => :select_queued,
    {["alt"], "e"} => :revise_queued,
    {["alt"], "u"} => :unstage_queued,
    {["alt"], "z"} => :revoke_steer,
    {[], "esc"} => :dismiss,
    {["ctrl"], "j"} => :newline,
    {["ctrl"], "o"} => :pager,
    {["ctrl"], "r"} => :history_search,
    {["ctrl"], "g"} => :external_editor,
    {["ctrl"], "v"} => :paste_image,
    {[], "back_tab"} => :cycle_mode,
    {["shift"], "back_tab"} => :cycle_mode,
    {["alt"], "n"} => :toggle_notifications
  }

  defstruct bindings: @defaults

  @doc "Every action a key can be bound to, in the order the moduledoc lists them."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc """
  The words a config file may put on the right of a binding.

  `actions/0` as strings, and `forward`, which releases a key to the editor.
  Public so the message `Lemieux.CLI.Config` prints can list the same words
  this accepts.
  """
  @spec names() :: [String.t()]
  def names, do: Enum.map(@actions, &Atom.to_string/1) ++ ["forward"]

  @doc "The shipped table as data, which is what a map from `from_map/1` overrides."
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  The shipped table: what each key does when nothing has rebound it.

  `docs/cli.md` lists the same bindings, and the TUI input and view tests press them.
  """
  @impl __MODULE__
  @spec action(key :: key()) :: action() | :forward
  def action(key), do: action(default(), key)

  @doc """
  What `key` does under `keys`, which is whatever a host configured.

  `nil` is the shipped table, a `t:t/0` is looked up, and a module is asked
  — so `Lemieux.TUI` holds "whatever was configured" in one field and asks
  one question of it. A module that answers outside the vocabulary gets its
  answer back as `{:unknown, answer}`: the screen forwards the key and says
  what the module said, rather than crashing on a host's bug or hiding it.
  """
  @spec action(keys :: module() | t() | nil, key :: key()) ::
          action() | :forward | {:unknown, term()}
  def action(nil, key), do: action(default(), key)

  def action(%__MODULE__{bindings: bindings}, %{code: code, modifiers: modifiers})
      when is_binary(code) and is_list(modifiers),
      do: Map.get(bindings, binding(code, modifiers), :forward)

  def action(%__MODULE__{}, _key), do: :forward

  def action(module, key) when is_atom(module) do
    case module.action(key) do
      answer when answer in @actions or answer == :forward -> answer
      other -> {:unknown, other}
    end
  end

  @doc """
  Reads a key map from the shape a config file holds.

  Every entry is a key description to an action name or `forward`. Entries
  are merged over the shipped table; the problems come back together, each
  naming the entry it was found in, and the two invariants in the moduledoc
  are checked over the result.
  """
  @spec from_map(map :: term()) :: {:ok, t()} | {:error, [String.t()]}
  def from_map(map) when is_map(map) and not is_struct(map) do
    {entries, problems} =
      Enum.reduce(map, {[], []}, fn entry, {entries, problems} ->
        case read_entry(entry) do
          {:ok, described, binding, action} ->
            {[{described, binding, action} | entries], problems}

          {:error, problem} ->
            {entries, [problem | problems]}
        end
      end)

    entries = Enum.sort_by(entries, fn {described, _binding, _action} -> described end)
    problems = Enum.sort(problems) ++ conflicts(entries)

    with [] <- problems,
         bindings = merged(entries),
         :ok <- interruptible(bindings) do
      {:ok, %__MODULE__{bindings: bindings}}
    else
      {:error, problem} -> {:error, [problem]}
      problems -> {:error, problems}
    end
  end

  def from_map(_other), do: {:error, ["keys must be a map of key descriptions to action names"]}

  @doc """
  `from_map/1`, raising on a map it cannot read.

  For the host that passed the map in code, where a binding that is not one
  is a programming error and a screen that quietly kept the defaults would
  hide it. A config file is checked before it gets this far.
  """
  @spec from_map!(map :: term()) :: t()
  def from_map!(map) do
    case from_map(map) do
      {:ok, keys} -> keys
      {:error, problems} -> raise ArgumentError, "keys: " <> Enum.join(problems, "; ")
    end
  end

  @doc """
  Writes a key map back as the shape a config file holds.

  Every binding in force, defaults included, each key in its canonical
  spelling — modifiers as `ctrl`, `alt`, `shift` in that order — so that
  `from_map/1` of the result is the same table.
  """
  @spec to_map(keys :: t()) :: %{String.t() => String.t()}
  def to_map(%__MODULE__{bindings: bindings}),
    do: Map.new(bindings, fn {binding, action} -> {describe(binding), Atom.to_string(action)} end)

  @doc """
  Parses one key description into a `t:binding/0`, or says what is wrong
  with it. The grammar is in the moduledoc.
  """
  @spec parse(description :: String.t()) :: {:ok, binding()} | {:error, String.t()}
  def parse(description) when is_binary(description) do
    {modifiers, code} = description |> String.trim() |> String.downcase() |> split()

    with :ok <- modifier_problems(modifiers),
         {:ok, code} <- read_code(code) do
      {:ok, {Enum.sort(modifiers), code}}
    end
  end

  @doc "Writes a `t:binding/0` in its canonical spelling."
  @spec describe(binding :: binding()) :: String.t()
  def describe({modifiers, code}) when is_list(modifiers) and is_binary(code) do
    ordered = Enum.filter(["ctrl", "alt", "shift"], &(&1 in modifiers))

    Enum.join(ordered ++ [written(code)], "-")
  end

  # The key an event is looked up under. Modifiers outside the grammar are
  # dropped rather than failing the lookup, and a character is lower-cased:
  # a terminal that reports shift-a as `"A"` with shift held is describing the
  # same key as one that reports `"a"`.
  defp binding(code, modifiers) do
    {modifiers |> Enum.filter(&(&1 in @modifiers)) |> Enum.uniq() |> Enum.sort(),
     String.downcase(code)}
  end

  defp read_entry({description, name}) when is_binary(description) do
    with {:ok, binding} <- parse(description),
         {:ok, action} <- read_action(name) do
      {:ok, description, binding, action}
    else
      {:error, problem} -> {:error, "#{inspect(description)}: #{problem}"}
    end
  end

  defp read_entry({description, _name}),
    do: {:error, "#{inspect(description)}: a key must be described as a string"}

  defp read_action("forward"), do: {:ok, :forward}

  defp read_action(name) when is_binary(name) do
    case Enum.find(@actions, &(Atom.to_string(&1) == name)) do
      nil -> {:error, "#{inspect(name)} is not an action (#{Enum.join(names(), ", ")})"}
      action -> {:ok, action}
    end
  end

  defp read_action(other),
    do: {:error, "#{inspect(other)} is not an action (#{Enum.join(names(), ", ")})"}

  # `String.split/2` on `-` turns a trailing hyphen key into two empty parts,
  # which is how `ctrl--` and a bare `-` are told from `ctrl-`, where the key
  # is simply missing.
  defp split(description) do
    case description |> String.split("-") |> Enum.reverse() do
      ["", "" | modifiers] -> {Enum.reverse(modifiers), "-"}
      [code | modifiers] -> {Enum.reverse(modifiers), code}
    end
  end

  defp modifier_problems(modifiers) do
    cond do
      unknown = Enum.find(modifiers, &(&1 not in @modifiers)) ->
        {:error, "#{unknown} is not a modifier (#{Enum.join(@modifiers, ", ")})"}

      modifiers != Enum.uniq(modifiers) ->
        {:error, "a modifier is given twice"}

      true ->
        :ok
    end
  end

  defp read_code(""), do: {:error, "no key after the modifiers"}
  defp read_code("space"), do: {:ok, " "}

  defp read_code(code) do
    if code in @named_keys or String.length(code) == 1,
      do: {:ok, code},
      else:
        {:error,
         "#{code} is not a key: a single character, or one of #{Enum.join(@named_keys, ", ")}"}
  end

  defp written(" "), do: "space"
  defp written(code), do: code

  # Two descriptions that normalise to one binding and disagree about it. The
  # ones that agree are simply the same entry written twice.
  defp conflicts(entries) do
    entries
    |> Enum.group_by(fn {_described, binding, _action} -> binding end)
    |> Enum.flat_map(fn {_binding, group} ->
      described = Enum.map(group, fn {described, _binding, _action} -> described end)
      actions = group |> Enum.map(fn {_described, _binding, action} -> action end) |> Enum.uniq()

      if length(actions) > 1,
        do: [
          Enum.join(described, " and ") <>
            " are the same key, bound to " <> Enum.map_join(actions, " and ", &Atom.to_string/1)
        ],
        else: []
    end)
    |> Enum.sort()
  end

  defp merged(entries) do
    Enum.reduce(entries, @defaults, fn {_described, binding, action}, bindings ->
      Map.put(bindings, binding, action)
    end)
  end

  defp interruptible(bindings) do
    if :interrupt in Map.values(bindings),
      do: :ok,
      else:
        {:error,
         "interrupt is bound to nothing: it is the only way out of a running turn, " <>
           "so give it another key before taking ctrl-c for something else"}
  end
end
