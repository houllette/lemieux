defmodule Lemieux.AgentSessionErrorsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Agent.Session
  alias Lemieux.Benchmark.Runtime.Native
  alias Lemieux.Benchmark.Task
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tools.{Read, Write}

  @moduletag :tmp_dir

  defmodule HostGuard do
    @behaviour Lemieux.Session.Guard

    @impl true
    def decide(_state, _view), do: {:stop, :host_limit, "HTTP 503: host says enough"}
  end

  setup do
    runtime = :"agent_errors_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime}
  end

  test "successful repeating writes stop locally in both agent and native benchmark observations",
       ctx do
    for adapter <- [:agent, :native], kind <- [:stuck, :cycling] do
      cwd = Path.join(ctx.tmp_dir, "#{adapter}-#{kind}")
      File.mkdir!(cwd)
      File.write!(Path.join(cwd, "result"), if(kind == :cycling, do: "0", else: "same"))

      script =
        for turn <- 1..8 do
          content = if kind == :cycling, do: Integer.to_string(rem(turn, 2)), else: "same"

          Scripted.tool_call("write-#{turn}", "write", %{"path" => "result", "content" => content})
        end

      script =
        if kind == :cycling,
          do: [Scripted.tool_call("read", "read", %{"path" => "result"}) | script],
          else: script

      assert {:ok, observation} = run(adapter, %{ctx | tmp_dir: cwd}, Scripted.new(script))
      assert observation["status"] == "failed"
      assert observation["finish_reason"] == ":no_progress"
      assert observation["provider_error"] == nil
      assert %{"stop_reason" => "no_progress", "reason" => reason} = observation["harness_error"]
      assert reason =~ "stopped"
      assert_local_error(observation, reason)

      results = Enum.filter(observation["transcript"], &(&1["type"] == "tool_result"))
      assert length(results) >= 3
      assert length(results) <= 9
      assert Enum.all?(results, &(&1["payload"]["error"] == false))

      assert reason =~ if(kind == :stuck, do: "same thing", else: "repeated an earlier call")
    end
  end

  test "turn budgets and custom guard reasons retain typed local diagnostics", ctx do
    for {options, stop_reason} <- [
          {[max_turns: 1], "max_turns"},
          {[guard: HostGuard], "host_limit"}
        ] do
      provider =
        Scripted.new([
          Scripted.tool_call("write", "write", %{"path" => "result", "content" => "done"})
        ])

      assert {:ok, observation} = run(:agent, ctx, provider, options)
      assert observation["provider_error"] == nil
      assert %{"stop_reason" => ^stop_reason, "reason" => reason} = observation["harness_error"]
      assert_local_error(observation, reason)
      assert observation["finish_reason"] == ":" <> stop_reason
    end
  end

  test "an unclassified provider failure remains a provider error", ctx do
    # This is also the old turn-limit wording. A provider's text is never
    # evidence that the harness produced it.
    provider = Scripted.new([Scripted.error("stopped after 3 turns")])
    assert {:ok, observation} = run(:agent, ctx, provider)
    assert observation["finish_reason"] == ":error"
    assert observation["harness_error"] == nil

    assert observation["provider_error"] == %{
             "reason" => "stopped after 3 turns",
             "category" => "other",
             "http_status" => nil,
             "code" => nil
           }

    error = Enum.find(observation["transcript"], &(&1["type"] == "error"))
    assert error["payload"]["source"] == "provider"
  end

  test "a request budget keeps its tuple-shaped terminal reason local", ctx do
    provider =
      Scripted.new([
        Scripted.tool_call("write", "write", %{"path" => "budget-result", "content" => "done"})
      ])

    assert {:ok, observation} = run(:agent, ctx, provider, max_requests: 1)
    assert observation["provider_error"] == nil
    assert %{"stop_reason" => "budget", "reason" => reason} = observation["harness_error"]
    assert_local_error(observation, reason)
    assert observation["finish_reason"] =~ "{:budget,"
    assert length(Scripted.requests(provider)) == 1
  end

  defp assert_local_error(observation, reason) do
    error = Enum.find(observation["transcript"], &(&1["type"] == "error"))
    assert error["payload"]["reason"] == reason
    assert error["payload"]["source"] == "harness"
  end

  defp run(adapter, ctx, provider, options \\ []) do
    input = %{prompt: "write", cwd: ctx.tmp_dir, timeout_ms: 60_000}

    opts = [
      provider: provider,
      model: "test:model",
      supervisor: ctx.runtime,
      sessions_dir: Path.join(ctx.tmp_dir, "sessions"),
      session_options: [tools: [Read, Write], provider_retry: false] ++ options
    ]

    case adapter do
      :agent -> Session.run(input, opts)
      :native -> Native.run(struct!(Task, Map.merge(input, %{id: "writes", grader: nil})), opts)
    end
  end
end
