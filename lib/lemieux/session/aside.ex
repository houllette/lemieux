defmodule Lemieux.Session.Aside do
  @moduledoc """
  One model request a host asks a session to make between turns, without
  tools: a review, a judgement, a summary for a screen. `Lemieux.Session.aside/2`
  runs it.

  ## Why a value and not a mode

  Reflection used to be a second request mode inside the loop: a flag read at
  nine points that swapped the system text, dropped the tools, changed the
  request kind and short-circuited compaction, reference expansion and the
  stop hook's retry. Every one of those points was there because a
  transcript-grounded review needs them — and none of them was about
  *reviewing*. A host that wanted a different review prompt, or a host-side
  judge scoring the run, would have had to become a third mode.

  So the loop keeps the mechanism and gives up the opinion. An aside says
  what to send and how to label it; the session sends it the way it sends a
  turn — through the provider, the budget gate, the harness snapshot,
  telemetry and the transcript — and refuses tools whatever the model asks.
  `Lemieux.Reflection.reflect/2` is one caller. Another host writes another.

  ## Fields

    * `kind` — the request kind recorded in the `:request` entry's snapshot,
      so a reader of the transcript can tell this request from a turn's. An
      atom of the caller's choosing; `:reflection` is what `/reflect` uses.
    * `text` — the prompt, written as a `:user` entry like any other and
      shown to the `user_prompt` hook. It is not expanded for `@`-references:
      an aside is a request a program composed, not a line a person typed.
    * `system` — the system text for this one request. It replaces the
      turn's; the next turn gets its own back.
    * `entries` — what to send ahead of the prompt. A list of
      `Lemieux.Entry` (empty by default, so the evidence lives in `system`
      and the request is one prompt) or `:transcript`, which sends what the
      next turn would have sent, summary included.
    * `output_schema` — an optional structured-output schema, as a turn's
      `:output_schema` option.
  """

  alias Lemieux.Entry

  @typedoc "What an aside sends ahead of its own prompt."
  @type entries :: [Entry.t()] | :transcript

  @type t :: %__MODULE__{
          kind: atom(),
          text: String.t(),
          system: String.t(),
          entries: entries(),
          output_schema: term() | nil
        }

  @enforce_keys [:kind, :text, :system]
  defstruct kind: nil, text: nil, system: nil, entries: [], output_schema: nil

  @doc """
  Builds an aside, refusing one that could not be sent.

  A missing key raises as `struct!/2` does; a `kind` that is not an atom, a
  `text` or `system` that is not a string, or `entries` of neither shape
  raise here rather than inside the session, where the caller has already
  been answered `:ok`.
  """
  @spec new(fields :: keyword()) :: t()
  def new(fields) when is_list(fields) do
    aside = struct!(__MODULE__, fields)

    unless is_atom(aside.kind) and is_binary(aside.text) and is_binary(aside.system) and
             entries?(aside.entries) do
      raise ArgumentError,
            "an aside needs an atom kind, a text and a system, and entries that are a " <>
              "list or :transcript; got #{inspect(aside)}"
    end

    aside
  end

  defp entries?(:transcript), do: true
  defp entries?(entries) when is_list(entries), do: Enum.all?(entries, &match?(%Entry{}, &1))
  defp entries?(_other), do: false
end
