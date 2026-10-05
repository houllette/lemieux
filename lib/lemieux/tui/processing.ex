# Unguarded, unlike `Lemieux.TUI` itself: this is a list of words and a choice
# between them, with no widget and no NIF in it. `Lemieux.CLI.Config` validates a
# configured list at load, on a machine that may never have had the optional
# terminal dependency installed, and cannot reach a module that only exists when
# it does.
defmodule Lemieux.TUI.Processing do
  @moduledoc """
  What the live row calls a turn while it is running.

  The label used to be the word `Processing`, permanently. It is the single
  most-looked-at string this program draws — it is on screen for the whole of
  every turn — and a fixed one tells you nothing you did not already know from
  the elapsed seconds beside it. One word per turn, drawn from a list, makes
  the moment a new turn starts visible at a glance rather than only in a
  timer that has gone back to zero.

  Per *turn*, not per request. A turn is one prompt and however many model
  requests its tool loop takes, and a label that changed on each of those
  would be a word dancing in the corner of the screen for two minutes while
  nothing a person cares about had changed.

  ## The list is not a joke at the reader's expense

  Half of these are the plain words — `Processing`, `Working`, `Computing` —
  and the other half are not, because a harness somebody sits in front of all
  day is allowed some personality. What none of them do is *claim* anything:
  there is no word here that says the model is nearly done, or that it is
  doing something in particular. What it is actually doing is the phase text
  beside it, which is measured; this is a label, and a label that guessed
  would be worse than one that amused.

  For that reason too, nothing here repeats a phase's own vocabulary —
  `thinking`, `answering`, `composing`, `running`, `waiting`, `reading`,
  `retrying`. `Thinking… · thinking (40s)` reads as a stutter, and worse, as
  two different claims about the same thing.

  ## Configuring it

  `"processing"` in `~/.lmx/config.json` replaces the list wholesale rather
  than adding to it — somebody who wants one word back wants *only* that word,
  and a list that merged would make that impossible. `Lemieux.CLI.Config`
  checks it at load: non-empty strings, none longer than `max_length/0`,
  because the row wraps to two at most and a long label pushes the phase text
  into the second of them on a narrow terminal.
  """

  # Thirteen columns at the longest, which is where `@max_length` comes from
  # rather than the other way round: the shipped list has to pass the check a
  # configured one does.
  @words [
    "Processing",
    "Working",
    "Computing",
    "Crunching",
    "Churning",
    "Chewing",
    "Puzzling",
    "Pondering",
    "Mulling",
    "Deliberating",
    "Ruminating",
    "Cogitating",
    "Noodling",
    "Percolating",
    "Simmering",
    "Brewing",
    "Steeping",
    "Whirring",
    "Ticking",
    "Grinding",
    "Cranking",
    "Assembling",
    "Untangling",
    "Unravelling",
    "Wrangling",
    "Marshalling",
    "Rummaging",
    "Spelunking",
    "Excavating",
    "Consulting",
    "Conferring",
    "Divining",
    "Scheming",
    "Plotting",
    "Drafting",
    "Sketching",
    "Tinkering",
    "Fiddling",
    "Rearranging",
    "Triangulating",
    "Extrapolating",
    "Hypothesising",
    "Overthinking",
    "Reticulating",
    "Yak-shaving",
    "Bikeshedding",
    "Nerd-sniping",
    "Vibing",
    "Cooking",
    "Forechecking",
    "Backchecking",
    "Stickhandling",
    "Zamboniing",
    "Skating",
    "Deking"
  ]

  # `Stickhandling` and `Triangulating` are the longest at thirteen, and a
  # configured label is allowed the same room and no more. The live row wraps to
  # two rows at most and drops what will not fit, so what a longer label costs is
  # the phase text beside it, which is the half worth keeping.
  @max_length 13

  @doc """
  Every label a turn can be given, when nothing has replaced the list.
  """
  @spec words() :: [String.t()]
  def words, do: @words

  @doc """
  The longest a label may be, in graphemes.

  Public because `Lemieux.CLI.Config` refuses a longer one at load and the
  message it prints has to say the same number this enforces.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Whether a configured list is one this can draw from.

  A list rather than a string: replacing the list with one word is a list of
  one. An empty list is not "no labels", it is a configuration that left the
  live row with nothing to say, so it is rejected rather than silently
  falling back — a setting that is ignored when it is wrong is a setting
  nobody can debug.
  """
  @spec valid?(words :: term()) :: boolean()
  def valid?(words) when is_list(words) and words != [],
    do: Enum.all?(words, &valid_word?/1)

  def valid?(_words), do: false

  defp valid_word?(word) when is_binary(word) do
    trimmed = String.trim(word)

    trimmed != "" and String.length(trimmed) <= @max_length and
      not String.contains?(word, ["\n", "\r"])
  end

  defp valid_word?(_word), do: false

  @doc """
  One label, at random, from a configured list or the shipped one.

  `nil` and an empty list both mean the shipped list, so callers do not have
  to decide which kind of absence they are holding. `:rand` rather than a
  cycle through the list in order: a cycle is a sequence somebody eventually
  learns, and then the label is telling them nothing again.
  """
  @spec pick(words :: [String.t()] | nil) :: String.t()
  def pick(words \\ nil)
  def pick(words) when is_list(words) and words != [], do: Enum.random(words)
  def pick(_none), do: Enum.random(@words)
end
