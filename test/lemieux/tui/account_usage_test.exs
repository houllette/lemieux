defmodule Lemieux.TUI.AccountUsageTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.TUI

  test "one Enter starts reporting, delivers its result and permits cached reads and refresh" do
    owner = self()
    report = %{fetched_at: System.system_time(:second), accounts: []}
    session = fake_session(snapshot("01SESSION"))

    state =
      TUI.new(
        id: "01SESSION",
        session: session,
        test_mode: {80, 24},
        account_usage: fn ->
          send(owner, :reporting)
          report
        end
      )

    state = put_in(state.conversation.busy?, true)
    pending = state |> type("/usage") |> press("enter")
    assert typed(pending) == ""
    assert hd(pending.history.entries) == "/usage"
    assert screen(pending) =~ "Fetching provider account usage"
    assert_receive :reporting
    assert_receive {:account_usage_result, id, {:ok, ^report, _}} = result
    assert pending.conversation.usage_request_id == id
    assert {:noreply, done} = TUI.handle_info(result, pending)
    assert done.conversation.usage_request_id == nil
    assert done.conversation.account_usage == report
    assert done.conversation.busy?
    assert screen(done) =~ "Provider account usage"

    cached = done |> type("/usage") |> press("enter")
    assert screen(cached) =~ "cached"
    refute_receive :reporting, 20

    refreshed = cached |> type("/usage refresh") |> press("enter")
    assert_receive :reporting
    assert_receive {:account_usage_result, refresh_id, _} = result
    assert refresh_id != id
    assert {:noreply, refreshed} = TUI.handle_info(result, refreshed)
    assert refreshed.conversation.usage_request_id == nil
    refute_receive {:prompted, _}, 20
    refute_receive {:steered, _}, 20
  end

  test "reporter failures clear pending work, allow retry and ignore a previous session's reply" do
    state =
      TUI.new(
        test_mode: {80, 24},
        account_usage: fn -> raise "fixture failed" end
      )
      |> type("/usage")
      |> press("enter")

    assert_receive {:account_usage_result, id, {:error, _}} = failure
    assert {:noreply, failed} = TUI.handle_info(failure, state)
    assert failed.conversation.usage_request_id == nil
    assert screen(failed) =~ "reporter failed"

    retried = failed |> type("/usage refresh") |> press("enter")
    assert retried.conversation.usage_request_id != id
    assert_receive {:account_usage_result, _, {:error, _}} = retry_failure
    assert {:noreply, retried} = TUI.handle_info(retry_failure, retried)
    assert retried.conversation.usage_request_id == nil

    switched = %{retried | conversation: Lemieux.Conversation.new()}
    assert {:noreply, ignored} = TUI.handle_info(failure, switched)
    assert ignored.lines == switched.lines
    assert ignored.conversation == switched.conversation
  end

  test "an unsupported host gives an immediate explanation and clears its pending request" do
    state = TUI.new(test_mode: {80, 24}) |> type("/usage") |> press("enter")
    assert state.conversation.usage_request_id == nil
    assert screen(state) =~ "no provider account usage reporter"
  end

  test "timeout reports are displayed and another refresh can start" do
    report = %{
      fetched_at: System.system_time(:second),
      accounts: [%{provider: "test", status: :error, message: "Reporting timed out"}]
    }

    state =
      TUI.new(test_mode: {80, 24}, account_usage: fn -> report end)
      |> type("/usage")
      |> press("enter")

    assert_receive {:account_usage_result, _, {:ok, ^report, _}} = result
    assert {:noreply, done} = TUI.handle_info(result, state)
    assert done.conversation.usage_request_id == nil
    assert screen(done) =~ "Reporting timed out"
    retried = done |> type("/usage refresh") |> press("enter")
    assert_receive {:account_usage_result, id, _} = result
    assert retried.conversation.usage_request_id == id
    assert {:noreply, done} = TUI.handle_info(result, retried)
    assert done.conversation.usage_request_id == nil
  end
end
