defmodule Lemieux.Extensions.Interactive do
  @moduledoc """
  Puts `ask_user` in the catalog, because somebody is there to answer.

  `Lemieux.Tools.AskUser` parks a call until a person types a reply. In a
  host with nobody attached — `lmx run`, a script, a CI job — that is a call
  that waits out its timeout and comes back denied, so the tool belongs to
  the hosts that can answer it and to no execution profile. The TUI applies
  this; `lmx run` does not, and a library host applies it when it
  has a channel to a person. A catalog that already carries `ask_user` is
  left alone rather than given a second one.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, _state) do
    Harness.update_tools(harness, fn tools ->
      if Enum.any?(tools, &(Tool.name(&1) == "ask_user")),
        do: tools,
        else: tools ++ [Tools.AskUser]
    end)
  end
end
