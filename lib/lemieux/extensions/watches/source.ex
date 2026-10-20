defmodule Lemieux.Extensions.Watches.Source do
  @moduledoc """
  A host-selected observer of an existing external activity.

  Targets are bounded inert JSON identity, never commands to start work.
  `validate/2` pins that identity before registration; `observe/2` must only
  inspect it. Credentials and clients stay in adapter state. Observations run
  in supervised, deadline-limited tasks, with bounded concurrency. A retry
  carries the source's rate-limit delay; no inference runs while waiting.
  Hosts can bridge subscriptions by having this callback read a cached event.
  """

  @type observation ::
          {:pending, String.t()}
          | {:retry, pos_integer(), String.t()}
          | {:done, map()}
          | {:error, :authentication | :unavailable | :failed, String.t()}

  @callback validate(state :: term(), target :: map()) :: {:ok, map()} | {:error, term()}
  @callback observe(state :: term(), target :: map()) :: observation()
end
