defmodule Lemieux.Conversation.Command.Help do
  @moduledoc """
  `/help`: the command list, which each front end draws for itself.

  The parse answers the list as a line. The TUI swaps that line for the
  `:help` action before dispatch so its host
  policy can filter the list and refuse the command typed by hand — see
  `Lemieux.TUI`. Nothing reaches the session either way, which is why
  `perform/3` has nothing to do.

  Two pieces of the TUI's list live here so they are spelled one way:
  `key_label/1`, which writes a key as a person would say it rather than in
  the key map's grammar, and `links/0`, the lines the list ends with.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.CLI.Help, as: CLIHelp
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Columns

  @impl Lemieux.Conversation.Command
  def spec, do: %{name: "help", description: "show commands", action: :help}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, conversation),
    do: Conversation.ready_unless_busy(conversation, [{:say, Conversation.help(conversation)}])

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc

  @doc """
  A key description (`Lemieux.TUI.Keys`) as `/help` shows it.

  The key map is written in crossterm's names, and `/help` printed them as
  they were: `back_tab, shift-back_tab` for the key everybody calls
  Shift-Tab — the one that changes the permission mode — and `page_up` for
  Page Up. Named keys are words here, and both spellings of Shift-Tab are the
  one label, so a caller that maps over a binding list should drop the
  duplicate. Only a named key's underscores are spaces: `_` bound on its own
  is a character, and stays one.

      iex> Lemieux.Conversation.Command.Help.key_label("shift-back_tab")
      "shift-tab"
      iex> Lemieux.Conversation.Command.Help.key_label("page_up")
      "page up"
      iex> Lemieux.Conversation.Command.Help.key_label("ctrl-_")
      "ctrl-_"
  """
  @spec key_label(key :: String.t()) :: String.t()
  def key_label(key) when is_binary(key) do
    {modifiers, code} = modifiers(key, [])

    {modifiers, code} =
      if code == "back_tab", do: {["shift" | modifiers], "tab"}, else: {modifiers, code}

    ordered = Enum.filter(~w(ctrl alt shift), &(&1 in modifiers))
    Enum.join(ordered ++ [named(code)], "-")
  end

  # `Lemieux.TUI.Keys.describe/1`'s grammar: modifiers, each followed by a
  # hyphen, then the key — which may itself be `-`.
  defp modifiers("ctrl-" <> code, acc) when code != "", do: modifiers(code, ["ctrl" | acc])
  defp modifiers("alt-" <> code, acc) when code != "", do: modifiers(code, ["alt" | acc])
  defp modifiers("shift-" <> code, acc) when code != "", do: modifiers(code, ["shift" | acc])
  defp modifiers(code, acc), do: {acc, code}

  defp named(code) do
    if String.length(code) > 1, do: String.replace(code, "_", " "), else: code
  end

  @doc """
  The lines the terminal UI's `/help` ends with: where the guides are, where
  to report a bug and where to ask (`Lemieux.CLI.Help.links/0`, which
  `lmx --help` ends with too). Before them nothing in lmx said where any of
  the three was.
  """
  @spec links() :: String.t()
  def links do
    rows = Enum.map(CLIHelp.links(), fn {label, url} -> {String.downcase(label), url} end)
    "More\n" <> (rows |> Columns.format() |> Enum.join("\n"))
  end
end
