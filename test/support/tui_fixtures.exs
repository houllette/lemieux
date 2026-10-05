# Two status lines a host might write, which is what the extension point is
# for: one that reformats the row, and one that gets the geometry wrong.
defmodule Lemieux.TUITest.HostStatus do
  @moduledoc false
  @behaviour Lemieux.TUI.Status

  alias ExRatatui.Widgets.Paragraph

  @impl Lemieux.TUI.Status
  def render(status, area) do
    [{%Paragraph{text: "host line · #{status.label} · #{status.width} wide"}, area}]
  end
end

defmodule Lemieux.TUITest.TallStatus do
  @moduledoc false
  @behaviour Lemieux.TUI.Status

  alias ExRatatui.Widgets.Paragraph

  @impl Lemieux.TUI.Status
  def height, do: 2

  @impl Lemieux.TUI.Status
  def render(_status, _area) do
    # Deliberately the whole screen: the obvious mistake in writing one of
    # these is placing a widget where it goes *within* the row.
    [{%Paragraph{text: "two rows"}, %ExRatatui.Layout.Rect{x: 0, y: 0, width: 200, height: 99}}]
  end
end

# A follow-up guess a host might write: one rule of its own, nothing else.
defmodule Lemieux.TUITest.HostFollowup do
  @moduledoc false
  @behaviour Lemieux.TUI.Followup

  @impl Lemieux.TUI.Followup
  def suggest(%{edits: edits}) when edits > 0, do: "open a pull request"
  def suggest(_signals), do: nil
end

# A receipt a host might write for `read`: a heading of its own instead of a
# line under `Explored`, and the size read instead of nothing when it lands.
defmodule Lemieux.TUITest.ReadCard do
  @moduledoc false
  @behaviour Lemieux.TUI.Renderer

  @impl Lemieux.TUI.Renderer
  def call(call, _exploring?),
    do: [{:tool_heading, call.id, :explore, "Opened", call.arguments["path"]}]

  @impl Lemieux.TUI.Renderer
  def result(call, result, _theme),
    do:
      {:replace,
       [{:tool_heading, call.id, :explore, "Opened", "#{byte_size(result.output)} bytes"}]}
end

# A tool a hook can park, so an approval has something to be about.
defmodule Lemieux.TUITest.Echo do
  @moduledoc false
  @behaviour Lemieux.Tool

  @impl Lemieux.Tool
  def name, do: "echo"
  @impl Lemieux.Tool
  def description, do: "Echoes what it is given."
  @impl Lemieux.Tool
  def schema, do: %{"type" => "object", "properties" => %{}}
  @impl Lemieux.Tool
  def run(%{"say" => say}, _context), do: {:ok, "echo: #{say}"}
  @impl Lemieux.Tool
  def parallel_safe?, do: true
end

# A receipt that restyles the approval card too: the shape a host with an
# approval policy of its own would write.
defmodule Lemieux.TUITest.ApprovalCard do
  @moduledoc false
  @behaviour Lemieux.TUI.Renderer

  @impl Lemieux.TUI.Renderer
  def call(call, _exploring?),
    do: [{:tool_heading, call.id, :run, "Echoing", call.arguments["say"]}]

  @impl Lemieux.TUI.Renderer
  def approval(call),
    do: [{:tool_heading, call.id, :approval, "May echo say", "#{call.arguments["say"]}?"}]
end

# A host's own slash command, and one that takes a built-in's name.
defmodule Lemieux.TUITest.Wave do
  @moduledoc false
  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{
      name: "wave",
      description: "wave at the room",
      accepts_arguments?: true,
      action: {:wave, nil}
    }

  @impl Lemieux.Conversation.Command
  def parse(whom, _conversation), do: [{:wave, String.trim(whom)}]

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:wave, whom}),
    do: Dispatch.say(acc, host, "waved at #{whom}")

  @impl Lemieux.Conversation.Command
  def completions(_typed, _conversation), do: ["alice", "bob"]
end

defmodule Lemieux.TUITest.HostModel do
  @moduledoc false
  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{
      name: "model",
      description: "pick from the host's catalog",
      accepts_arguments?: true,
      action: {:host_model, nil}
    }

  @impl Lemieux.Conversation.Command
  def parse(spec, _conversation), do: [{:host_model, String.trim(spec)}]

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:host_model, spec}),
    do: Dispatch.say(acc, host, "the host picked #{spec}")
end

# A key map a host might write: two vi-shaped scroll keys, and the shipped
# table for everything else.
defmodule Lemieux.TUITest.ViKeys do
  @moduledoc false
  @behaviour Lemieux.TUI.Keys

  alias Lemieux.TUI.Keys

  @impl Keys
  def action(%{code: "k", modifiers: ["ctrl"]}), do: :scroll_up
  def action(%{code: "j", modifiers: ["ctrl"]}), do: :scroll_down
  def action(key), do: Keys.action(key)
end

# A key map that answers something outside the vocabulary.
defmodule Lemieux.TUITest.OddKeys do
  @moduledoc false
  @behaviour Lemieux.TUI.Keys

  alias Lemieux.TUI.Keys

  @impl Keys
  def action(%{code: "x", modifiers: []}), do: :launch
  def action(key), do: Keys.action(key)
end

# Two layouts a host might write: the screen upside down, and one that puts
# the transcript under the other two panes.
defmodule Lemieux.TUITest.UpsideDown do
  @moduledoc false
  @behaviour Lemieux.TUI.Layout

  alias ExRatatui.Layout.Rect

  @impl Lemieux.TUI.Layout
  def panes(%{width: width, height: height}, %{input: input, status: status}) do
    %{
      input: %Rect{x: 0, y: 0, width: width, height: input},
      status: %Rect{x: 0, y: input, width: width, height: status},
      transcript: %Rect{x: 0, y: input + status, width: width, height: height - input - status}
    }
  end
end

defmodule Lemieux.TUITest.Overlapping do
  @moduledoc false
  @behaviour Lemieux.TUI.Layout

  alias ExRatatui.Layout.Rect

  @impl Lemieux.TUI.Layout
  def panes(%{width: width, height: height}, %{input: input, status: status}) do
    %{
      transcript: %Rect{x: 0, y: 0, width: width, height: height},
      status: %Rect{x: 0, y: height - input - status, width: width, height: status},
      input: %Rect{x: 0, y: height - input, width: width, height: input}
    }
  end
end
