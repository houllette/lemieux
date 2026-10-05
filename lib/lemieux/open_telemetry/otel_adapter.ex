defmodule Lemieux.OpenTelemetry.OTelAdapter do
  @moduledoc """
  Default `Lemieux.OpenTelemetry.Adapter` backed by the Erlang OTel API.

  Every call is dynamic so adding Lemieux to a host does not add or start an
  OpenTelemetry SDK. A host that already configured an SDK and exporter owns
  both; attaching `Lemieux.OpenTelemetry` simply obtains a named tracer from
  that provider and therefore inherits the host's connection automatically.
  """

  @behaviour Lemieux.OpenTelemetry.Adapter

  @otel_schema_url "https://opentelemetry.io/schemas/1.37.0"

  @impl true
  def available? do
    Enum.all?(
      [
        {:opentelemetry, :get_tracer, 3},
        {:otel_ctx, :new, 0},
        {:otel_ctx, :get_current, 0},
        {:otel_ctx, :attach, 1},
        {:otel_ctx, :detach, 1},
        {:otel_tracer, :current_span_ctx, 0},
        {:otel_tracer, :set_current_span, 2},
        {:otel_tracer, :start_span, 4},
        {:otel_span, :is_valid, 1},
        {:otel_span, :set_attributes, 2},
        {:otel_span, :add_event, 3},
        {:otel_span, :set_status, 2},
        {:otel_span, :end_span, 1}
      ],
      fn {module, function, arity} ->
        Code.ensure_loaded?(module) and function_exported?(module, function, arity)
      end
    )
  end

  @impl true
  def current_context(_config) do
    span = call(:otel_tracer, :current_span_ctx, [])

    if span != :undefined and call(:otel_span, :is_valid, [span]) do
      %{context: call(:otel_ctx, :get_current, []), span: span}
    end
  end

  @impl true
  def start_span(name, kind, attributes, parent, _config) do
    parent_context = parent_context(parent)

    span =
      call(:otel_tracer, :start_span, [
        parent_context,
        tracer(),
        name,
        %{kind: kind, attributes: attributes}
      ])

    %{context: call(:otel_tracer, :set_current_span, [parent_context, span]), span: span}
  end

  @impl true
  def activate_context(%{context: context}, _config), do: call(:otel_ctx, :attach, [context])

  @impl true
  def detach_context(token, _config) do
    _ = call(:otel_ctx, :detach, [token])
    :ok
  end

  @impl true
  def set_attributes(%{span: span}, attributes, _config) do
    _ = call(:otel_span, :set_attributes, [span, attributes])
    :ok
  end

  @impl true
  def add_event(%{span: span}, name, attributes, _config) do
    _ = call(:otel_span, :add_event, [span, name, attributes])
    :ok
  end

  @impl true
  def set_status(%{span: span}, status, _config) do
    _ = call(:otel_span, :set_status, [span, status])
    :ok
  end

  @impl true
  def end_span(%{span: span}, _config) do
    _ = call(:otel_span, :end_span, [span])
    :ok
  end

  @doc false
  @spec inject_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def inject_headers(headers) when is_list(headers) do
    if propagation_available?() do
      propagator = call(:opentelemetry, :get_text_map_injector, [])

      call(:otel_propagator_text_map, :inject, [
        propagator,
        headers,
        fn key, value, carrier -> [{to_string(key), to_string(value)} | carrier] end
      ])
    else
      headers
    end
  rescue
    _error -> headers
  end

  defp parent_context(%{context: context}), do: context
  defp parent_context(nil), do: call(:otel_ctx, :new, [])

  defp propagation_available? do
    Enum.all?(
      [
        {:opentelemetry, :get_text_map_injector, 0},
        {:otel_propagator_text_map, :inject, 3}
      ],
      fn {module, function, arity} ->
        Code.ensure_loaded?(module) and function_exported?(module, function, arity)
      end
    )
  end

  defp tracer do
    call(:opentelemetry, :get_tracer, [:lemieux, Lemieux.version(), @otel_schema_url])
  end

  defp call(module, function, arguments), do: apply(module, function, arguments)
end
