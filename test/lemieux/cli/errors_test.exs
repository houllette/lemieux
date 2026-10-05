defmodule Lemieux.CLI.ErrorsTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Errors

  test "a transcript open in another lmx names the holder and the way out" do
    holder = %{host: "devbox", os_pid: 4242, since: ~U[2026-09-28 10:00:00Z], path: "/s/x.lock"}
    sentence = Errors.describe({:session_locked, holder})

    assert sentence =~ "open in another lmx"
    assert sentence =~ "pid 4242"
    assert sentence =~ "2026-09-28 10:00"
    assert sentence =~ "delete /s/x.lock"
  end

  test "a missing key names the variable to set and never offers /retry" do
    sentence = Errors.describe({:missing_api_key, "anthropic", "Set :api_key option, config …"})

    assert sentence =~ "ANTHROPIC_API_KEY"
    refute sentence =~ "/retry"
    refute sentence =~ ":api_key option"
  end

  test "stop reasons and errors map to the documented exit statuses" do
    assert Errors.exit_status(Errors.category(:stop, nil)) == 0
    assert Errors.exit_status(Errors.category(:cancelled, nil)) == 5
    assert Errors.exit_status(Errors.category({:budget, %{kind: :requests}}, nil)) == 4
    assert Errors.exit_status(Errors.category(:max_turns, nil)) == 4
    assert Errors.exit_status(Errors.category(:error, {:missing_api_key, "x", "h"})) == 3
    assert Errors.exit_status(Errors.category(:error, %{status: 401})) == 3
    assert Errors.exit_status(Errors.category(:error, %{status: 503})) == 6
    assert Errors.exit_status(Errors.category(:error, :something_else)) == 1
  end
end
