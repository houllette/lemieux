defmodule Lmx.Update.CallbacksTest do
  use ExUnit.Case, async: true
  alias Lmx.Update.Callbacks

  test "retained local callbacks and callbacks captured in other closures require restart" do
    local = fn -> :retained end
    changed = [Atom.to_string(__MODULE__)]
    refute Callbacks.safe_term?(%{hook: local}, changed)
    wrapper = fn -> local.() end
    refute Callbacks.safe_term?([%{nested: {wrapper, :other}}], changed)
    assert Callbacks.safe_term?(local, ["Elixir.Unrelated"])
    assert Callbacks.safe_term?(&String.trim/1, ["Elixir.String"])
  end

  test "default screen callbacks resolve outside changing render/event code" do
    state = Lemieux.TUI.new(id: "callbacks", model: "test:model")
    assert Callbacks.safe_term?(state, ["Elixir.Lemieux.TUI"])
    refute Callbacks.safe_term?(state, ["Elixir.Lemieux.TUI.Callbacks"])
    assert is_integer(state.clock.())
    assert state.terminal.title.("test") == :ok
    custom = %{state | clock: fn -> 0 end}
    refute Callbacks.safe_term?(custom, [Atom.to_string(__MODULE__)])
  end

  test "an unavailable screen cannot qualify a live update" do
    refute Callbacks.safe?(self(), ["Elixir.Lemieux"])
  end
end
