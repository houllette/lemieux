# A turn's clock, usage, and summary are updated together.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Turn do
    @moduledoc "Tracks a TUI turn's activity and measured token usage."

    alias Lemieux.TUI
    alias Lemieux.TUI.Activity
    alias Lemieux.TUI.Followup
    alias Lemieux.TUI.Processing
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Transcript

    @tick_ms 250
    @doc false
    @spec tick_ms() :: pos_integer()
    def tick_ms, do: @tick_ms

    @doc false
    @spec start_processing(TUI.t()) :: TUI.t()
    def start_processing(%TUI{turn: %{started_at: started}} = state)
        when is_integer(started),
        do: state

    def start_processing(state) do
      token = make_ref()
      Process.send_after(self(), {:activity_tick, token}, @tick_ms)

      %{
        state
        | turn: %{
            started_at: state.clock.(),
            tick: token,
            frame: 2,
            label: Processing.pick(state.status.words),
            usage: empty_processing_usage(),
            signals: Followup.empty(),
            phase: nil,
            delegation: nil,
            compacting: nil
          }
      }
    end

    @doc false
    @spec finish_processing(TUI.t()) :: TUI.t()
    def finish_processing(%TUI{turn: %{started_at: nil}} = state),
      do: stop_processing(state)

    def finish_processing(state) do
      elapsed = Screen.elapsed(state)
      usage = state.turn.usage

      summary =
        [
          Activity.duration(elapsed),
          plural(usage.requests, "req"),
          processing_tokens(usage),
          plural(usage.tool_calls, "tool call")
        ]
        |> Enum.join(" · ")

      state
      |> Transcript.say(:summary, summary)
      |> stop_processing()
    end

    # The spinner's timer. Only the running turn's own token advances it; a turn
    # that ended between ticks winds down here rather than spinning on.
    @doc false
    @spec tick(TUI.t(), reference()) :: {:noreply, TUI.t()}
    def tick(%TUI{turn: %{tick: token}} = state, token) do
      if state.conversation.busy? do
        Process.send_after(self(), {:activity_tick, token}, @tick_ms)
        {:noreply, put_in(state.turn.frame, state.turn.frame + 1)}
      else
        {:noreply, stop_processing(state)}
      end
    end

    def tick(state, _token), do: {:noreply, state}

    # Signals and usage survive: the summary line and the follow-up hint are both
    # drawn about a turn that has ended. The line being written is closed here too —
    # a fence the model never closed should not stay open across the next prompt.
    @doc false
    @spec stop_processing(TUI.t()) :: TUI.t()
    def stop_processing(state),
      do: %{
        Transcript.close_line(state)
        | turn: %{state.turn | started_at: nil, tick: nil, frame: 0, phase: nil, delegation: nil}
      }

    @doc false
    @spec idle_turn() :: TUI.turn()
    def idle_turn do
      %{
        started_at: nil,
        tick: nil,
        frame: 0,
        label: nil,
        usage: empty_processing_usage(),
        signals: Followup.empty(),
        phase: nil,
        delegation: nil,
        compacting: nil
      }
    end

    defp empty_processing_usage do
      %{
        input: 0,
        cache_read: 0,
        cache_write: 0,
        output: 0,
        tokens: 0,
        requests: 0,
        tool_calls: 0,
        cost_usd: nil,
        measured?: false
      }
    end

    @doc false
    @spec add_usage(TUI.processing_usage(), map()) :: TUI.processing_usage()
    def add_usage(current, usage) do
      cached = usage_count(usage, "cache_read_tokens")
      cache_write = usage_count(usage, "cache_write_tokens")
      input = usage_count(usage, "input_tokens")

      input =
        if usage_value(usage, "input_includes_cached") in [true, "true"],
          do: max(input - cached - cache_write, 0),
          else: input

      output = usage_count(usage, "output_tokens")
      tokens = input + cached + cache_write + output
      cost = usage_value(usage, "cost_usd")

      %{
        input: current.input + input,
        cache_read: current.cache_read + cached,
        cache_write: current.cache_write + cache_write,
        output: current.output + output,
        tokens: current.tokens + tokens,
        requests: current.requests + 1,
        tool_calls: current.tool_calls,
        cost_usd: add_cost(current, cost),
        measured?: true
      }
    end

    defp usage_count(usage, key) do
      case usage_value(usage, key) do
        value when is_integer(value) and value >= 0 -> value
        value when is_float(value) and value >= 0 -> trunc(value)
        _other -> 0
      end
    end

    defp usage_value(usage, key), do: Map.get(usage, key)

    defp add_cost(%{measured?: false}, cost) when is_number(cost), do: cost

    defp add_cost(%{cost_usd: total}, cost) when is_number(total) and is_number(cost),
      do: total + cost

    defp add_cost(_usage, _cost), do: nil

    defp processing_tokens(%{measured?: false}), do: "tokens unmeasured"

    defp processing_tokens(usage) do
      "#{compact_number(usage.tokens)} total tokens " <>
        "(#{compact_number(usage.input)} in · " <>
        "#{compact_number(usage.cache_read)}/#{compact_number(usage.cache_write)} cache · " <>
        "#{compact_number(usage.output)} out)"
    end

    defp plural(1, noun), do: "1 #{noun}"
    defp plural(amount, noun), do: "#{amount} #{noun}s"

    @doc false
    @spec compact_number(non_neg_integer()) :: String.t()
    def compact_number(amount) when amount < 1_000, do: Integer.to_string(amount)

    def compact_number(amount) when amount < 1_000_000,
      do: :erlang.float_to_binary(amount / 1_000, decimals: 1) <> "k"

    def compact_number(amount),
      do: :erlang.float_to_binary(amount / 1_000_000, decimals: 1) <> "m"
  end
end
