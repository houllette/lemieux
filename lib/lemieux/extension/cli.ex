defmodule Lemieux.Extension.CLI do
  @moduledoc """
  Runs a compiled session extension through the ordinary Lemieux CLI hosts.

  An installed Mix dependency supplies its profile and `:tool_registry` in code;
  JSON never names modules to load. TUI and headless runs share the same
  profile resolver used by `Profile.configure/2`. Tools remain subject to the
  host's hooks and environment. Arbitrary pipeline agents own their interactive
  adapter; use this entry point for session-based agents with reusable tools.
  """

  @doc "Opens the TUI (empty argv) or a headless task (`run`, prompt)."
  @spec run(profile :: map(), argv :: [String.t()], opts :: keyword()) ::
          :ok | {:error, pos_integer()}
  def run(profile, argv \\ [], opts \\ []) do
    Lemieux.CLI.run(argv, Keyword.put(opts, :extension_profile, profile))
  end
end
