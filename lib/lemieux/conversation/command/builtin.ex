defmodule Lemieux.Conversation.Command.Builtin do
  @moduledoc """
  The commands `lmx` ships, in the order `/help` lists them.

  A list rather than anything discovered: which modules answer at the prompt
  is a decision, and a directory scan would make it an accident of what was
  compiled. `Lemieux.Conversation.Command.registry/1` puts a host's own
  modules ahead of these and drops any of these a host module shadows.

  ## The order

  Everyday first — which model, which session, keeping the context in
  check, stopping and retrying, seeing and undoing what the agent did —
  then the settings, then the switches a person uses once a week, then the
  research tooling, which a person reaches for deliberately. `/help` and
  the completion menu both read this order, and a menu that opened on
  `/reflect` taught people it was the command to reach for.

  ## What is not here

  `/elixir`, `/attach` and `/detach` are about one kind of project: they
  switch to the Elixir evaluator and point it at a running node, and are
  noise in a Python repository. They are `elixir/0`, which a host hands to
  `Lemieux.Extensions.Elixir` as its `:commands` when it applies it, so they
  are offered exactly where the Elixir tooling is.
  """

  alias Lemieux.Conversation.Command

  @doc "Every built-in command module, help order first, hidden ones last."
  @spec all() :: [module()]
  def all do
    [
      Command.Model,
      Command.Provider,
      Command.Effort,
      Command.New,
      Command.Resume,
      Command.Compact,
      Command.Context,
      Command.Cancel,
      Command.Unsteer,
      Command.Retry,
      Command.Undo,
      Command.Rewind,
      Command.Redo,
      Command.Diff,
      Command.Shell,
      Command.Copy,
      Command.Export,
      Command.Init,
      Command.Memory,
      Command.Permissions,
      Command.Approve,
      Command.Deny,
      Command.Verify,
      Command.Delegate,
      Command.Tools,
      Command.MCP,
      Command.Prompts,
      Command.Name,
      Command.Color,
      Command.Theme,
      Command.Refresh,
      Command.Update,
      Command.Doctor,
      Command.Help,
      Command.Quit,
      Command.Reflect,
      Command.Feedback,
      Command.Habs
    ]
  end

  @doc """
  The Elixir-project commands — `/elixir`, `/attach`, `/detach` — for a host
  to give `Lemieux.Extensions.Elixir` as `commands:`. See the moduledoc.
  """
  @spec elixir() :: [module()]
  def elixir, do: [Command.Elixir, Command.Attach, Command.Detach]
end
