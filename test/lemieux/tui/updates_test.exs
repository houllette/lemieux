defmodule Lemieux.TUI.UpdatesTest do
  use ExUnit.Case, async: true
  alias Lemieux.TUI
  alias Lemieux.TUI.Notices
  alias Lemieux.TUI.Updates

  # Update notices are news about lmx, so they go to the notice box rather
  # than the transcript; the newest is the one a step just said.
  defp newest_notice(state), do: state |> Notices.items() |> List.last()

  test "startup and session changes arm one recurring check, without overlapping work" do
    owner = self()
    tasks = start_supervised!(Task.Supervisor)

    host = %{
      tasks: tasks,
      auto?: false,
      check?: true,
      check: fn ->
        send(owner, {:checking, self()})

        receive do
          :finish -> :current
        end
      end
    }

    state =
      TUI.new(test_mode: {80, 24}, id: "checks", model: "test:model", updates: host)
      |> Updates.start()

    assert_receive :check_update
    assert {token, timer} = state.status.update.timer
    assert Process.read_timer(timer) in 1..3_600_000
    {:noreply, checking} = TUI.handle_info(:check_update, state)
    assert_receive {:checking, task}
    {:noreply, periodic} = TUI.handle_info({:update_check, token}, checking)
    assert periodic.status.update.task == checking.status.update.task
    refute_receive {:checking, _}, 20
    send(task, :finish)
    ref = periodic.status.update.task.ref
    assert_receive {^ref, result}
    {:noreply, ready} = TUI.handle_info({ref, result}, periodic)
    assert {next_token, next_timer} = ready.status.update.timer
    refute next_token == token
    {:noreply, polling} = TUI.handle_info({:update_check, next_token}, ready)
    assert_receive {:checking, next_task}
    send(next_task, :finish)
    ref = polling.status.update.task.ref
    assert_receive {^ref, result}
    state = Updates.result(polling, result)
    restarted = Updates.start(state)
    assert_receive :check_update
    refute Process.read_timer(next_timer)
    assert {:noreply, ^restarted} = TUI.handle_info({:update_check, token}, restarted)
    Updates.stop(restarted)
  end

  test "periodic notices are deduplicated and disabled checks create no timer" do
    tasks = start_supervised!(Task.Supervisor)

    host = %{
      tasks: tasks,
      auto?: false,
      check?: true,
      check: fn -> {:ok, %{"version" => "0.2.0"}} end
    }

    state = TUI.new(test_mode: {80, 24}, id: "notices", model: "test:model", updates: host)
    first = check_result(state)
    second = check_result(first)
    assert [%{kind: :info, text: "Lemieux v0.2.0 is available · /update"}] = Notices.items(first)
    assert Notices.items(second) == Notices.items(first)
    assert second.lines == first.lines
    assert second.status.update.phase == :available

    disabled =
      TUI.new(
        test_mode: {80, 24},
        id: "off",
        model: "test:model",
        updates: Map.put(host, :check?, false)
      )
      |> Updates.start()

    assert disabled.status.update.timer == nil
    refute_receive :check_update, 20
    assert Updates.request(disabled).status.update.phase == :check
  end

  defp check_result(state) do
    checking = Updates.check(state)
    ref = checking.status.update.task.ref
    assert_receive {^ref, result}
    {:noreply, checked} = TUI.handle_info({ref, result}, checking)
    checked
  end

  test "staging completes during a turn, but activation waits for idle and pauses input" do
    caller = self()
    tasks = start_supervised!(Task.Supervisor)

    host = %{
      tasks: tasks,
      auto?: true,
      check: fn -> {:ok, %{"version" => "0.2.0"}} end,
      stage: fn info -> {:ok, %{version: info["version"]}} end,
      apply: fn staged, app ->
        send(caller, {:activated, staged, app})
        {:ok, :restart}
      end
    }

    state = TUI.new(test_mode: {80, 24}, id: "update", model: "test:model", updates: host)
    state = put_in(state.conversation.busy?, true)
    {:noreply, state} = TUI.handle_info(:check_update, state)
    ref = state.status.update.task.ref
    assert_receive {^ref, result}
    {:noreply, state} = TUI.handle_info({ref, result}, state)
    ref = state.status.update.task.ref
    assert_receive {^ref, result}
    {:noreply, state} = TUI.handle_info({ref, result}, state)
    assert state.status.update.phase == :staged
    refute_receive {:activated, _, _}
    state = put_in(state.conversation.busy?, false)
    {:noreply, state} = TUI.handle_info(:update_idle, state)
    assert state.status.update.phase == :apply

    assert {:noreply, ^state} =
             TUI.handle_event(%ExRatatui.Event.Paste{content: "new prompt"}, state)

    assert_receive {:activated, %{version: "0.2.0"}, app}
    assert app == self()
    ref = state.status.update.task.ref
    assert_receive {^ref, result}
    {:noreply, state} = TUI.handle_info({ref, result}, state)
    assert state.status.update.phase == :restart
    assert %{kind: :info, text: notice} = newest_notice(state)
    assert notice =~ "restart lmx"
  end

  test "hosts can decline installation, and an opt-out waits for /update" do
    state = TUI.new(test_mode: {80, 24}, id: "source", model: "test:model") |> Updates.request()
    assert %{kind: :warning, text: notice} = newest_notice(state)
    assert notice =~ "does not provide update installation callbacks"
    tasks = start_supervised!(Task.Supervisor)

    host = %{
      tasks: tasks,
      auto?: false,
      check: fn -> {:ok, %{"version" => "0.2.0"}} end,
      stage: fn _ -> {:error, :offline} end,
      apply: fn _, _ -> flunk("must not activate") end
    }

    state =
      TUI.new(test_mode: {80, 24}, id: "manual", model: "test:model", updates: host)
      |> Updates.check()

    ref = state.status.update.task.ref
    assert_receive {^ref, result}
    state = Updates.result(state, result)
    assert state.status.update.phase == :available
    assert state.status.update.task == nil
    state = Updates.request(state)
    ref = state.status.update.task.ref
    assert_receive {^ref, result}
    {:noreply, state} = TUI.handle_info({ref, result}, state)
    assert state.status.update.phase == :idle
    assert %{kind: :error, text: notice} = newest_notice(state)
    assert notice =~ "could not be completed"
  end

  test "restart reminders survive resume, offline checks and later release checks" do
    tasks = start_supervised!(Task.Supervisor)
    host = %{tasks: tasks, auto?: false, check?: true, check: fn -> :current end}
    state = TUI.new(test_mode: {80, 24}, id: "restart", model: "test:model", updates: host)
    state = put_in(state.status.update.phase, :apply)
    state = put_in(state.status.update.pending, %{info: %{"version" => "0.2.0"}})
    state = Updates.result(state, {:ok, :restart})
    assert {_, timer} = state.status.update.timer
    assert Process.read_timer(timer) > 0
    restarted = Updates.start(Notices.dismiss(state))
    assert_receive :check_update
    assert Enum.any?(Notices.items(restarted), &(&1.text =~ "restart"))
    checked = check_result(restarted)
    assert checked.status.update.phase == :restart
    assert checked.status.update.installed == "0.2.0"
    checking = Updates.check(checked)
    ref = checking.status.update.task.ref
    assert_receive {^ref, _}
    checked = Updates.result(checking, {:error, :offline})
    assert checked.status.update.phase == :restart
    checking = Updates.check(checked)
    ref = checking.status.update.task.ref
    assert_receive {^ref, _}
    newer = Updates.result(checking, {:ok, %{"version" => "0.3.0"}})
    assert newer.status.update.phase == :available
    assert newer.status.update.pending["version"] == "0.3.0"
    Updates.stop(newer)
  end

  test "invalid callback results and a failed rollback produce honest notices" do
    tasks = start_supervised!(Task.Supervisor)
    host = %{tasks: tasks, auto?: false, check: fn -> {:ok, :invalid} end}

    checked =
      TUI.new(test_mode: {80, 24}, id: "invalid", model: "test:model", updates: host)
      |> check_result()

    assert checked.status.update.phase == :idle
    applying = put_in(checked.status.update.phase, :apply)
    failed = Updates.result(applying, {:error, {:rollback_failed, :example}})
    assert %{kind: :error, text: notice} = newest_notice(failed)
    assert notice =~ "restart"
    refute notice =~ "session is still open"
  end

  test "an unverified release is said once per version, again on request, and never staged" do
    tasks = start_supervised!(Task.Supervisor)
    owner = self()

    host = %{
      tasks: tasks,
      auto?: true,
      check?: true,
      check: fn -> {:unverified, "0.2.0", :signature_invalid} end,
      stage: fn _ -> send(owner, :staged) end,
      apply: fn _, _ -> send(owner, :applied) end,
      unverified_notice: fn version, reason -> "v#{version} was not installed (#{reason})" end
    }

    first =
      TUI.new(test_mode: {80, 24}, id: "unverified", model: "test:model", updates: host)
      |> check_result()

    assert [%{kind: :warning, text: "v0.2.0 was not installed (signature_invalid)"}] =
             Notices.items(first)

    assert %{phase: :idle, task: nil, pending: nil} = first.status.update
    second = check_result(Notices.dismiss(first))
    assert Notices.items(second) == []

    requested = Updates.request(second)
    assert requested.status.update.phase == :check
    ref = requested.status.update.task.ref
    assert_receive {^ref, result}
    {:noreply, answered} = TUI.handle_info({ref, result}, requested)
    assert [%{kind: :warning, text: "v0.2.0 was not installed" <> _}] = Notices.items(answered)
    refute_received :staged
    refute_received :applied

    # A newer version is news even unasked, and a host without its own wording
    # still says that nothing was installed.
    generic = %{host | check: fn -> {:unverified, "0.3.0", :signature_missing} end}

    newer =
      put_in(answered.status.update.host, Map.delete(generic, :unverified_notice))
      |> Notices.dismiss()
      |> check_result()

    assert [%{kind: :warning, text: notice}] = Notices.items(newer)
    assert notice =~ "v0.3.0"
    assert notice =~ "not installed"
  end

  test "a changed verdict about one release is news: verifying later is announced, failing again warns" do
    tasks = start_supervised!(Task.Supervisor)
    owner = self()

    host = %{
      tasks: tasks,
      auto?: false,
      check?: true,
      check: fn -> {:unverified, "0.2.0", :signature_missing} end,
      stage: fn _ -> send(owner, :staged) end,
      apply: fn _, _ -> send(owner, :applied) end,
      unverified_notice: fn version, reason -> "v#{version} not verified (#{reason})" end
    }

    unsigned =
      TUI.new(test_mode: {80, 24}, id: "verdicts", model: "test:model", updates: host)
      |> check_result()

    assert [%{kind: :warning, text: "v0.2.0 not verified (signature_missing)"}] =
             Notices.items(unsigned)

    assert unsigned |> Notices.dismiss() |> check_result() |> Notices.items() == []

    # The signature is published: with automatic installation off, this
    # notice is the only way anybody hears about the update.
    signed = put_in(unsigned.status.update.host.check, fn -> {:ok, %{"version" => "0.2.0"}} end)
    available = signed |> Notices.dismiss() |> check_result()

    assert [%{kind: :info, text: "Lemieux v0.2.0 is available · /update"}] =
             Notices.items(available)

    assert available.status.update.phase == :available
    assert available |> Notices.dismiss() |> check_result() |> Notices.items() == []

    tampered =
      put_in(available.status.update.host.check, fn ->
        {:unverified, "0.2.0", :signature_invalid}
      end)

    warned = tampered |> Notices.dismiss() |> check_result()

    assert [%{kind: :warning, text: "v0.2.0 not verified (signature_invalid)"}] =
             Notices.items(warned)

    assert %{phase: :idle, pending: nil} = warned.status.update
    refute_received :staged
    refute_received :applied
  end

  test "a host's error wording can defer to the default notice" do
    tasks = start_supervised!(Task.Supervisor)

    host = %{
      tasks: tasks,
      auto?: false,
      check: fn -> {:ok, %{"version" => "0.2.0"}} end,
      stage: fn info -> {:error, info["reason"]} end,
      apply: fn _, _ -> flunk("must not activate") end,
      error_notice: fn
        :signature_invalid -> "The signature did not verify."
        _other -> nil
      end
    }

    state = TUI.new(test_mode: {80, 24}, id: "errors", model: "test:model", updates: host)

    for {reason, expected} <- [
          signature_invalid: "The signature did not verify.",
          download_failed: "The update could not be completed · /update to retry."
        ] do
      staging =
        state
        |> put_in([Access.key!(:status), :update, :phase], :available)
        |> put_in([Access.key!(:status), :update, :pending], %{
          "version" => "0.2.0",
          "reason" => reason
        })
        |> Updates.request()

      ref = staging.status.update.task.ref
      assert_receive {^ref, result}
      {:noreply, failed} = TUI.handle_info({ref, result}, staging)
      assert %{kind: :error, text: text} = newest_notice(failed)
      assert String.starts_with?(text, expected)
      assert failed.status.update.phase == :idle
    end
  end

  test "another screen's installed update produces one restart reminder" do
    tasks = start_supervised!(Task.Supervisor)
    host = %{tasks: tasks, auto?: false, check: fn -> {:installed, "0.2.0"} end}

    first =
      TUI.new(test_mode: {80, 24}, id: "other-screen", model: "test:model", updates: host)
      |> check_result()

    assert first.status.update.phase == :restart
    assert first.status.update.installed == "0.2.0"
    assert [%{kind: :info, text: notice}] = Notices.items(first)
    assert notice =~ "restart"
    second = check_result(first)
    assert Notices.items(second) == Notices.items(first)
  end
end
