defmodule Lemieux.Extensions.Elixir do
  @moduledoc """
  The `--elixir` profile: one sharp instrument and nothing else — and the
  commands that go with it.

  A built-in tool profile rather than an additive capability. The catalog
  becomes `Lemieux.Tools.Eval` alone — no filesystem, no shell, no network
  tools — because a session meant to reason in a live BEAM should not also
  be able to reach around it; separately configured MCP servers still
  compose. The one thing kept from whatever was there is `ask_user`: it
  belongs to an attached interactive host rather than to either execution
  profile, so `Lemieux.Extensions.Interactive` applied before this one
  survives it, and a headless catalog stays headless.

  Applied after the extensions that fill the catalog and before
  `Lemieux.Extensions.Delegation`: the profile narrows what the parent may
  run, not who it may ask, and a scout that reads the working tree is the
  one thing an Elixir-only session cannot do for itself cheaply.

  ## Options

    * `:commands` — slash command modules to offer beside the profile:
      toggling it, attaching to a running node, detaching. Appended to the
      harness's `commands`, the way `Lemieux.Extensions.A2A` offers its own,
      so a screen lists them exactly where the Elixir tooling is and nowhere
      else. The host names the modules — they are the front end's — which
      keeps this extension from depending on a front end; `lmx` passes
      `Lemieux.Conversation.Command.Builtin.elixir/0`.
    * `:profile` — `true` (the default) narrows the catalog as above;
      `false` offers the commands alone and leaves the catalog as it is, for
      a host that wants `/elixir` available in an ordinary session of an
      Elixir project, to switch to the profile when it is wanted.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools

  @impl Lemieux.Extension
  def init(opts) when is_list(opts) do
    with {:ok, commands} <- commands(Keyword.get(opts, :commands, [])),
         {:ok, profile?} <- profile(Keyword.get(opts, :profile, true)) do
      {:ok, %{commands: commands, profile?: profile?}}
    end
  end

  defp commands(commands) when is_list(commands) do
    if Enum.all?(commands, &is_atom/1),
      do: {:ok, commands},
      else: {:error, ":commands must be a list of command modules"}
  end

  defp commands(_other), do: {:error, ":commands must be a list of command modules"}

  defp profile(profile?) when is_boolean(profile?), do: {:ok, profile?}
  defp profile(_other), do: {:error, ":profile must be true or false"}

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, state) do
    state = normalize(state)

    harness
    |> narrow(state.profile?)
    |> offer(state.commands)
  end

  # Applied as a bare module, before this extension took options, the state
  # is whatever `Lemieux.Extension` passes for no `init/1` result; that was
  # always the profile alone.
  defp normalize(%{commands: _commands, profile?: _profile?} = state), do: state
  defp normalize(_bare), do: %{commands: [], profile?: true}

  defp narrow(harness, false), do: harness

  defp narrow(harness, true) do
    Harness.update_tools(harness, fn tools ->
      [Tools.Eval | Enum.filter(tools, &(Tool.name(&1) == "ask_user"))]
    end)
  end

  defp offer(harness, []), do: harness

  defp offer(harness, commands),
    do: %{harness | commands: Enum.uniq(harness.commands ++ commands)}
end
