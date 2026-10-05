defmodule Lemieux.TUI.FirstRunOwnModelTest do
  @moduledoc """
  A key pasted into the provider panel's row for the person's own model
  (`own?: true`) is saved alone: the session stays on that model, and the
  config file's `"model"` is left as the person wrote it.
  """

  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.TUI

  @moduletag :tmp_dir

  defp opened(first_run, session) do
    [id: "01FIRSTRUN", model: "test:model", test_mode: {80, 24}, first_run: first_run]
    |> TUI.new()
    |> Map.put(:session, session)
    |> sized()
    |> TUI.FirstRun.open()
  end

  defp config(dir, model) do
    path = Path.join(dir, "config.json")
    File.write!(path, JSON.encode!(%{"version" => 1, "model" => model, "providers" => %{}}))
    path
  end

  defp row(env, fields) do
    Map.merge(
      %{id: "openai", label: "OpenAI", env: env, model: "openai:gpt-6-sol", credential: :missing},
      fields
    )
  end

  defp env do
    name = "LMX_FIRST_RUN_OWN_TEST_#{System.unique_integer([:positive])}"
    on_exit(fn -> System.delete_env(name) end)
    name
  end

  defp paste_key(state) do
    state = state |> press("enter") |> type("sk-test-key") |> press("enter")
    assert state.modal == nil
    state
  end

  test "the person's own model keeps its session and its place in the config file",
       %{tmp_dir: dir} do
    path = config(dir, "openai:gpt-4.1-mini")
    own = row(env(), %{model: "openai:gpt-4.1-mini", own?: true})
    session = fake_session(snapshot("01OWNMODEL"))

    state =
      opened(%{providers: [own], config_path: path, selected: "openai"}, session) |> paste_key()

    assert_receive {:first_run_saved, ^own, {:ok, true} = result}
    refute_received {:set_model, _model}

    saved = path |> File.read!() |> JSON.decode!()
    assert saved["model"] == "openai:gpt-4.1-mini"
    assert saved["providers"]["openai"]["api_key"] == "sk-test-key"
    assert System.get_env(own.env) == "sk-test-key"

    assert {:noreply, said} = TUI.handle_info({:first_run_saved, own, result}, state)
    text = said |> screen() |> String.replace(~r/\s+/, " ")
    assert text =~ "using openai:gpt-4.1-mini"
    refute text =~ "gpt-6-sol"
  end

  # The table's row still does what it always did: switch to its model and
  # save it as the one to start on.
  test "a table row still switches the session and saves its model", %{tmp_dir: dir} do
    path = config(dir, "anthropic:claude-sonnet-5")
    table = row(env(), %{})
    session = fake_session(snapshot("01TABLEROW"))

    opened(%{providers: [table], config_path: path, selected: "openai"}, session) |> paste_key()

    assert_receive {:first_run_saved, ^table, {:ok, true}}
    assert_received {:set_model, "openai:gpt-6-sol"}
    assert (path |> File.read!() |> JSON.decode!())["model"] == "openai:gpt-6-sol"
  end
end
