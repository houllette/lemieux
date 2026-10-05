defmodule Lemieux.Conversation.Command.Doctor do
  @moduledoc """
  `/doctor`: is this session in working order, in a few readable lines.

  The model and its key, the context window, the limits, the tools and MCP
  servers, the permission and checkpoint settings, where commands run and
  what the machine offers. `Lemieux.Conversation.Doctor` gathers and words
  it; gathering asks the session and probes the machine, so it runs off the
  host's draw loop and answers as `{:doctor_result, report}`. Allowed
  mid-turn: it reads and changes nothing.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Conversation.Doctor

  @impl Lemieux.Conversation.Command
  def spec, do: %{name: "doctor", description: "check this session's setup", action: :doctor}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, _conversation), do: [:doctor]

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :doctor),
    do:
      Dispatch.run(acc, host, fn ->
        {:doctor_result, host |> Doctor.gather() |> Doctor.format()}
      end)
end
