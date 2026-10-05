defmodule Lemieux.Benchmark.Progress do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Live, best-effort visibility for long benchmark runs.

  The reporter consumes the attempt events emitted by `Lemieux.Benchmark` and
  prints immediate start/finish lines plus periodic heartbeats for active work.
  It can also atomically maintain a small JSON status file for observers in a
  second terminal. Reporting and artifact failures never interrupt the paid
  benchmark.
  """

  use GenServer

  @default_interval_ms 20_000

  @type option ::
          {:total, pos_integer() | nil}
          | {:label, String.t()}
          | {:interval_ms, pos_integer()}
          | {:output, IO.device()}
          | {:artifact, Path.t() | nil}

  @doc "Starts a linked progress reporter."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Returns a non-blocking observer suitable for `Benchmark.run/3`."
  @spec callback(GenServer.server()) :: (map() -> :ok)
  def callback(reporter) do
    fn event ->
      GenServer.cast(reporter, {:progress, event})
      :ok
    end
  end

  @doc "Stops heartbeat reporting, persists final status, and prints a summary."
  @spec finish(GenServer.server(), atom()) :: :ok
  def finish(reporter, status \\ :completed), do: GenServer.call(reporter, {:finish, status})

  @doc "Returns the current JSON-shaped status."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(reporter), do: GenServer.call(reporter, :snapshot)

  @impl GenServer
  def init(opts) do
    interval = positive_option(opts, :interval_ms, @default_interval_ms)
    total = optional_positive_option(opts, :total)
    now = System.monotonic_time(:millisecond)

    state = %{
      label: Keyword.get(opts, :label, "benchmark"),
      total: total,
      output: Keyword.get(opts, :output, :stderr),
      artifact: Keyword.get(opts, :artifact),
      interval_ms: interval,
      timer: Process.send_after(self(), :heartbeat, interval),
      started_at: now,
      completed: 0,
      durations: [],
      active: %{},
      phase: nil,
      status: :running
    }

    safe_puts(
      state,
      "START #{state.label} · #{total_text(total)} · heartbeat #{duration(interval)}"
    )

    persist(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:progress, %{event: :attempt_started} = event}, state) do
    active = Map.put(state.active, event.id, Map.put(event, :started_at, now_ms()))
    state = %{state | active: active, phase: nil}

    safe_puts(
      state,
      "#{counter(state)} START #{event.runtime} · #{event.task_id} · attempt #{event.attempt}"
    )

    persist(state)
    {:noreply, state}
  end

  def handle_cast({:progress, %{event: :attempt_finished} = event}, state) do
    {_active, active} = Map.pop(state.active, event.id)
    completed = state.completed + 1
    elapsed = event.wall_time_ms

    state = %{
      state
      | active: active,
        completed: completed,
        durations: [elapsed | state.durations]
    }

    outcome = if event.passed, do: "PASS", else: "FAIL"

    detail =
      [
        outcome,
        event.runtime,
        "· #{event.task_id}",
        "· #{duration(elapsed)}",
        request_text(event.requests),
        reason_text(event.finish_reason, event.error),
        eta_text(state)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    safe_puts(state, "#{counter(state)} #{detail}")
    persist(state)
    {:noreply, state}
  end

  def handle_cast({:progress, %{event: :phase_started} = event}, state) do
    phase = Map.put(event, :started_at, now_ms())
    state = %{state | phase: phase}
    safe_puts(state, "#{counter(state)} START #{phase_name(event)}")
    persist(state)
    {:noreply, state}
  end

  def handle_cast({:progress, %{event: :phase_finished} = event}, state) do
    state = %{state | phase: nil}

    safe_puts(
      state,
      "#{counter(state)} #{String.upcase(to_string(event.status))} #{phase_name(event)} · #{duration(event.wall_time_ms)}"
    )

    persist(state)
    {:noreply, state}
  end

  def handle_cast({:progress, _unknown}, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, public_snapshot(state), state}

  def handle_call({:finish, status}, _from, state) do
    cancel_timer(state.timer)
    state = %{state | timer: nil, status: status, phase: nil}

    safe_puts(
      state,
      "DONE #{state.label} · #{state.completed}/#{state.total || "?"} attempts · #{duration(now_ms() - state.started_at)} · #{status}"
    )

    persist(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:heartbeat, %{status: :running} = state) do
    Enum.each(state.active, fn {_id, event} ->
      safe_puts(
        state,
        "#{counter(state)} RUNNING #{event.runtime} · #{event.task_id} · #{duration(now_ms() - event.started_at)} attempt#{deadline_text(event)} · #{duration(now_ms() - state.started_at)} total#{eta_text(state)}"
      )
    end)

    if map_size(state.active) == 0 and state.phase do
      safe_puts(
        state,
        "#{counter(state)} RUNNING #{phase_name(state.phase)} · #{duration(now_ms() - state.phase.started_at)} phase · #{duration(now_ms() - state.started_at)} total#{eta_text(state)}"
      )
    end

    state = %{state | timer: Process.send_after(self(), :heartbeat, state.interval_ms)}
    persist(state)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  defp public_snapshot(state) do
    now = now_ms()

    %{
      "schema_version" => 1,
      "label" => state.label,
      "status" => to_string(state.status),
      "completed" => state.completed,
      "total" => state.total,
      "elapsed_ms" => max(now - state.started_at, 0),
      "eta_ms" => eta_ms(state),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "active" =>
        Enum.map(state.active, fn {_id, event} ->
          remaining = remaining_ms(event, now)

          %{
            "task_id" => event.task_id,
            "runtime" => event.runtime,
            "attempt" => event.attempt,
            "elapsed_ms" => max(now - event.started_at, 0),
            "timeout_ms" => Map.get(event, :timeout_ms),
            "remaining_ms" => remaining,
            "overdue" => is_integer(remaining) and remaining < 0
          }
        end),
      "phase" =>
        if(state.phase,
          do: %{
            "name" => phase_name(state.phase),
            "elapsed_ms" => max(now - state.phase.started_at, 0)
          },
          else: nil
        )
    }
  end

  defp persist(%{artifact: nil}), do: :ok

  defp persist(state) do
    temporary = state.artifact <> ".tmp"
    File.mkdir_p!(Path.dirname(state.artifact))
    File.write!(temporary, JSON.encode!(public_snapshot(state)))
    File.rename!(temporary, state.artifact)
    :ok
  rescue
    _error -> :ok
  end

  defp safe_puts(state, message) do
    IO.puts(state.output, "[#{clock()}] #{message}")
  rescue
    _error -> :ok
  end

  defp counter(state), do: "[#{state.completed}/#{state.total || "?"}]"

  defp eta_text(state) do
    case eta_ms(state) do
      nil -> ""
      milliseconds -> " · ETA #{duration(milliseconds)}"
    end
  end

  defp eta_ms(%{total: total, durations: [_ | _] = durations, completed: completed})
       when is_integer(total) do
    remaining = max(total - completed, 0)
    round(Enum.sum(durations) / length(durations) * remaining)
  end

  defp eta_ms(_state), do: nil

  defp request_text(requests) when is_integer(requests), do: "· #{requests} requests"
  defp request_text(_requests), do: nil

  defp deadline_text(event) do
    case remaining_ms(event, now_ms()) do
      remaining when is_integer(remaining) and remaining >= 0 ->
        " · deadline in #{duration(remaining)}"

      remaining when is_integer(remaining) ->
        " · deadline exceeded by #{duration(abs(remaining))}"

      nil ->
        ""
    end
  end

  defp remaining_ms(%{timeout_ms: timeout, started_at: started}, now)
       when is_integer(timeout) and timeout > 0,
       do: timeout - max(now - started, 0)

  defp remaining_ms(_event, _now), do: nil

  defp reason_text(reason, nil) when reason not in [nil, ":stop"], do: "· #{reason}"
  defp reason_text(_reason, nil), do: nil
  defp reason_text(_reason, error), do: "· #{error}"

  defp phase_name(%{phase: phase, iteration: iteration}),
    do: "#{phase} iteration #{iteration}"

  defp phase_name(%{phase: phase}), do: to_string(phase)

  defp total_text(nil), do: "unknown attempt count"
  defp total_text(total), do: "#{total} attempts"

  defp duration(milliseconds) when is_integer(milliseconds) do
    seconds = max(div(milliseconds, 1_000), 0)
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)
    seconds = rem(seconds, 60)

    if hours > 0,
      do: :io_lib.format("~2..0B:~2..0B:~2..0B", [hours, minutes, seconds]) |> to_string(),
      else: :io_lib.format("~2..0B:~2..0B", [minutes, seconds]) |> to_string()
  end

  defp clock, do: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      invalid ->
        raise ArgumentError, ":#{key} must be a positive integer, got: #{inspect(invalid)}"
    end
  end

  defp optional_positive_option(opts, key) do
    case Keyword.get(opts, key) do
      nil ->
        nil

      value when is_integer(value) and value > 0 ->
        value

      invalid ->
        raise ArgumentError, ":#{key} must be a positive integer, got: #{inspect(invalid)}"
    end
  end
end
