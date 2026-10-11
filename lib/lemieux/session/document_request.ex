defmodule Lemieux.Session.DocumentRequest do
  @moduledoc false

  alias Lemieux.OpenTelemetry
  alias Lemieux.RequestSnapshot
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Audit
  alias Lemieux.Session.Core
  alias Lemieux.Session.Document
  alias Lemieux.Session.Instrumentation
  alias Lemieux.Session.Requests
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Usage

  def start(state, from, namespace, revision, request, build, opts) do
    request = %{
      request
      | tools: [],
        context:
          Map.merge(request.context, %{
            route_result_sink: self(),
            route_task_supervisor: Sup.task_supervisor(state.supervisor)
          })
    }

    with true <- available?(state),
         {:ok, %{revision: ^revision}} <- Document.read(state.reversed_entries, namespace),
         :ok <- Accounting.request_budget(state, request) do
      dispatch(state, from, namespace, revision, request, build, opts)
    else
      false -> {:reply, {:error, :busy}, state}
      {:ok, _document} -> {:reply, {:error, :conflict}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # A stop hook runs after the ordinary provider has ended. Holding that hook
  # while this request runs prevents a new turn spending the same remaining
  # cost allowance; no background reservation can race the next prompt.
  defp available?(%{hook_task: %{action: {:stop, _reason}}} = state),
    do: Core.status(%{state | hook_task: nil}) == :idle

  defp available?(state), do: Core.status(state) == :idle

  defp dispatch(state, from, namespace, revision, request, build, opts) do
    state = Audit.prepare_harness_snapshot(state, request)

    snapshot =
      request
      |> RequestSnapshot.build(
        Audit.request_snapshot_opts(state,
          kind: Keyword.get(opts, :kind, :document),
          catalog: [],
          auxiliary: true
        )
      )

    state = Core.append(state, {:request, snapshot, nil})
    request_id = RequestSnapshot.id(snapshot)
    route = Requests.provider_route(%{state | model: request.model})
    provider = state.provider

    metadata =
      Instrumentation.telemetry_metadata(state, %{request_id: request_id, kind: :document})

    session = self()
    ref = make_ref()

    task =
      Task.Supervisor.async_nolink(Sup.task_supervisor(state.supervisor), fn ->
        OpenTelemetry.with_context(route.id, :document, request_id, fn ->
          Accounting.run_provider(
            provider,
            route.limiter,
            route.limit_key,
            route.root_session_id,
            request,
            metadata,
            &send(session, {:document_event, ref, &1})
          )
        end)
      end)

    timer =
      Process.send_after(
        session,
        {:document_timeout, ref},
        Keyword.get(opts, :timeout_ms, 30_000)
      )

    pending = %{
      from: from,
      namespace: namespace,
      revision: revision,
      build: build,
      request_id: request_id,
      model: request.model,
      task: task,
      ref: ref,
      timer: timer,
      text: [],
      message: nil,
      usage: nil,
      outcome: nil
    }

    {:noreply, %{state | document_request: pending}}
  end

  def event(state, {:text_delta, text}),
    do: update(state, :text, [text | state.document_request.text])

  def event(state, {:message, message}), do: update(state, :message, message)

  def event(state, {:usage, usage}) when is_map(usage),
    do: update(state, :usage, Usage.normalize(usage, state.document_request.model))

  def event(state, {:response_metadata, metadata}),
    do:
      Core.emit(
        state,
        {:response_metadata, Map.put(metadata, :request_id, state.document_request.request_id)}
      )

  def event(%{document_request: %{outcome: {:error, _}}} = state, {:done, _reason}), do: state
  def event(state, {:done, _reason}), do: update(state, :outcome, :ok)
  def event(state, {:error, reason}), do: update(state, :outcome, {:error, reason})
  def event(state, {:tool_call, _call}), do: update(state, :outcome, {:error, :tools_refused})
  def event(state, _event), do: state

  defp update(state, key, value),
    do: %{state | document_request: Map.put(state.document_request, key, value)}

  def finish(state, returned) do
    pending = state.document_request
    Process.cancel_timer(pending.timer)
    result = outcome(pending, returned)
    value = build(pending.build, result)
    # A missing price never becomes free after resume. Even a crash or invalid
    # builder checkpoints unknown usage alongside the previous document value.
    usage =
      (pending.usage || Map.put(Usage.normalize(%{}, pending.model), "usage_reported", false))
      |> Map.put("request_id", pending.request_id)
      |> Map.put("source", "document")

    state = Accounting.account_external_usage(state, usage)
    {:ok, current} = Document.read(state.reversed_entries, pending.namespace)
    {reply, stored} = checkpoint(value, current, pending)
    state = Core.append(state, {:extension_state, stored, usage})
    # This usage changes cumulative spend, not the current conversation's
    # measured context position. Consumers refresh from the durable entry.
    GenServer.reply(pending.from, reply)
    %{state | document_request: nil}
  end

  defp checkpoint({:ok, value}, %{revision: revision}, %{revision: revision} = pending),
    do:
      {{:ok, %{revision: revision + 1, value: value}},
       payload(pending.namespace, revision + 1, value)}

  defp checkpoint(_value, current, pending) do
    error = if current.revision != pending.revision, do: :conflict, else: :invalid_document
    previous = current.value || %{}
    # Preserve the winning writer while recording the operation we still paid for.
    {{:error, error}, payload(pending.namespace, current.revision + 1, previous)}
  end

  defp payload(namespace, revision, value),
    do: %{"version" => 1, "namespace" => namespace, "revision" => revision, "value" => value}

  defp build(builder, result) do
    value = builder.(result)

    case Document.validate("result", value) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :invalid_document}
  catch
    _kind, _reason -> {:error, :invalid_document}
  end

  defp outcome(%{outcome: {:error, reason}}, _returned), do: {:error, reason}
  defp outcome(_pending, {:error, reason}), do: {:error, reason}

  defp outcome(%{outcome: :ok} = pending, :ok) do
    text = text(pending)
    if String.trim(text) == "", do: {:error, :empty_response}, else: {:ok, text}
  end

  defp outcome(_pending, _returned), do: {:error, :incomplete_stream}

  defp text(%{message: %{"content" => content}}) when is_list(content),
    do:
      Enum.map_join(content, fn
        %{"type" => "text", "text" => text} -> text
        _block -> ""
      end)

  defp text(pending), do: pending.text |> Enum.reverse() |> Enum.join()

  def cancel(%{document_request: nil} = state, _reason), do: state

  def cancel(state, reason) do
    Task.shutdown(state.document_request.task, 0)
    finish(state, {:error, reason})
  end
end
