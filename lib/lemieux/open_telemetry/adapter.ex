defmodule Lemieux.OpenTelemetry.Adapter do
  @moduledoc """
  Tracer boundary used by `Lemieux.OpenTelemetry`.

  The default implementation talks to the Erlang OpenTelemetry API only when
  the embedding host has installed it. The behaviour keeps that optional
  dependency out of Lemieux and gives tests and hosts a narrow customization
  seam without changing the public Telemetry event contract.
  """

  @callback available?() :: boolean()
  @callback current_context(config :: keyword()) :: term() | nil
  @callback start_span(
              name :: String.t(),
              kind :: atom(),
              attributes :: map(),
              parent_context :: term() | nil,
              config :: keyword()
            ) :: term()
  @callback activate_context(context :: term(), config :: keyword()) :: term()
  @callback detach_context(token :: term(), config :: keyword()) :: :ok
  @callback set_attributes(span :: term(), attributes :: map(), config :: keyword()) :: :ok
  @callback add_event(
              span :: term(),
              name :: String.t(),
              attributes :: map(),
              config :: keyword()
            ) :: :ok
  @callback set_status(span :: term(), status :: :ok | :error, config :: keyword()) :: :ok
  @callback end_span(span :: term(), config :: keyword()) :: :ok
end
