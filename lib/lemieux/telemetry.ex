defmodule Lemieux.Telemetry do
  @moduledoc """
  Stable, redacted telemetry for the harness-owned lifecycle.

  ReqLLM emits provider and token telemetry at its own seam. Lemieux adds the
  part only the harness can see: prompts, turns, limiter waits, provider work,
  first output, tools, compaction, and cancellation.

  Event names are deliberately low-cardinality and metadata is centrally
  allowlisted. Prompts, system text, tool arguments and output, credentials,
  endpoints, file paths, and arbitrary error terms are never emitted. Stable
  session, request and call ids are included for correlation; a host that uses
  tenant-sensitive ids should pseudonymize them before starting the session.
  `Lemieux.OpenTelemetry` can translate this contract into metadata-only spans
  without making an OpenTelemetry SDK or exporter a Lemieux dependency.

  Start/stop pairs use the ordinary Telemetry convention:

    * `[:lemieux, :session, :prompt, :start | :stop]`
    * `[:lemieux, :turn, :start | :stop]`
    * `[:lemieux, :provider, :request, :start | :stop | :exception]`
    * `[:lemieux, :provider, :first_delta]`
    * `[:lemieux, :provider_limiter, :wait, :start | :stop | :exception]`
    * `[:lemieux, :tool, :call, :start | :stop]`
    * `[:lemieux, :compaction, :start | :stop]`
    * `[:lemieux, :session, :cancel]`
    * `[:lemieux, :subagent, :admission, :start | :stop]` — how long a child
      waited between reservation and a runtime slot.
    * `[:lemieux, :subagent, :cancel, :start | :stop]` — how long a group took
      to bring every child to a terminal state, and whether any had to be
      terminated after the grace interval.
    * `[:lemieux, :subagent, :group, :pressure]` — the coordinator's own
      mailbox and memory while a fan-out runs.
    * `[:lemieux, :subagent, :progress]` — one soft-deadline check on a
      child: how long it had run, how many checks it has had, what the
      verdict was and who gave it.

  The three subagent events exist because the delegation plan makes them a
  precondition for widening the tree: breadth that is not measured is breadth
  nobody can say was safe. Usage summaries answer what a fan-out cost; these
  answer whether the coordinator kept up with it.

  Handlers run in the emitting process, as Telemetry handlers always do. Keep
  them fast and hand expensive export work to another process.
  """

  @allowed_metadata MapSet.new([
                      :session_id,
                      :root_session_id,
                      :request_id,
                      :provider,
                      :model,
                      :tool_name,
                      :call_id,
                      :entry_id,
                      :outcome,
                      :stop_reason,
                      :reason_category,
                      :kind,
                      # Subagent lifecycle correlation. `:group_id` and
                      # `:child_id` are runtime-generated ids like the session
                      # and request ids above, never host or tenant data;
                      # `:definition_id` is the host's own short definition
                      # name, which is configuration rather than content.
                      :group_id,
                      :child_id,
                      :definition_id,
                      # Who settled a progress check: the transcript rules,
                      # a model, the host, or nobody because it fell open.
                      :assessed_by
                    ])

  @typedoc "The event path below the `:lemieux` prefix."
  @type scope :: [atom()]

  @doc """
  Every metadata key an event may carry.

  Published because it is the whole redaction contract: anything not on this
  list is dropped before an event leaves, so a host auditing what reaches its
  exporter should read this rather than infer it from the events it happened
  to see. A test that restated the list instead of reading it drifted from the
  module the first time a key was added.
  """
  @spec metadata_keys() :: [atom()]
  def metadata_keys, do: @allowed_metadata |> MapSet.to_list() |> Enum.sort()

  @doc "Returns every public event name for attachment and discovery."
  @spec events() :: [[atom()]]
  def events do
    for {scope, suffixes} <- [
          {[:session, :prompt], [:start, :stop]},
          {[:turn], [:start, :stop]},
          {[:provider, :request], [:start, :stop, :exception]},
          {[:provider, :first_delta], [nil]},
          {[:provider_limiter, :wait], [:start, :stop, :exception]},
          {[:tool, :call], [:start, :stop]},
          {[:compaction], [:start, :stop]},
          {[:session, :cancel], [nil]},
          {[:subagent, :admission], [:start, :stop]},
          {[:subagent, :cancel], [:start, :stop]},
          {[:subagent, :group, :pressure], [nil]},
          {[:subagent, :progress], [nil]}
        ],
        suffix <- suffixes do
      [:lemieux | scope ++ List.wrap(suffix)]
    end
  end

  @doc "Emits a start event and returns its monotonic timestamp."
  @spec start(scope :: scope(), metadata :: map()) :: integer()
  def start(scope, metadata) do
    started_at = System.monotonic_time()

    :telemetry.execute(
      [:lemieux | scope ++ [:start]],
      %{monotonic_time: started_at, system_time: System.system_time()},
      metadata(metadata)
    )

    started_at
  end

  @doc "Emits a stop event using a timestamp returned by `start/2`."
  @spec stop(scope :: scope(), started_at :: integer(), metadata :: map(), measurements :: map()) ::
          :ok
  def stop(scope, started_at, metadata, measurements \\ %{}) do
    execute_stop(scope, System.monotonic_time() - started_at, metadata, measurements)
  end

  @doc "Emits a stop event when a caller already measured milliseconds."
  @spec stop_ms(scope :: scope(), duration_ms :: non_neg_integer(), metadata :: map()) :: :ok
  def stop_ms(scope, duration_ms, metadata) do
    duration = System.convert_time_unit(duration_ms, :millisecond, :native)
    execute_stop(scope, duration, metadata, %{})
  end

  @doc "Emits an exception event without putting the exception or stacktrace in metadata."
  @spec exception(scope :: scope(), started_at :: integer(), metadata :: map(), kind :: atom()) ::
          :ok
  def exception(scope, started_at, metadata, kind) do
    :telemetry.execute(
      [:lemieux | scope ++ [:exception]],
      %{duration: System.monotonic_time() - started_at, monotonic_time: System.monotonic_time()},
      metadata(Map.merge(metadata, %{kind: kind, outcome: :exception}))
    )
  end

  @doc "Emits an instantaneous event."
  @spec event(scope :: scope(), measurements :: map(), metadata :: map()) :: :ok
  def event(scope, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(
      [:lemieux | scope],
      Map.put_new(measurements(measurements), :monotonic_time, System.monotonic_time()),
      metadata(metadata)
    )
  end

  defp execute_stop(scope, duration, metadata, measurements) do
    :telemetry.execute(
      [:lemieux | scope ++ [:stop]],
      measurements |> measurements() |> Map.put(:duration, duration),
      metadata(metadata)
    )
  end

  defp metadata(metadata) do
    metadata
    |> Map.take(MapSet.to_list(@allowed_metadata))
    |> Map.filter(fn {_key, value} -> scalar?(value) end)
  end

  defp measurements(measurements) do
    Map.filter(measurements, fn {_key, value} -> is_number(value) end)
  end

  defp scalar?(value), do: is_binary(value) or is_atom(value) or is_number(value)
end
