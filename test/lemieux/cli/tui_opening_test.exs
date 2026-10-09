defmodule Lemieux.CLI.TUIOpeningTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.TUI
  alias Lemieux.TUI.Theme

  # The screen asks the terminal for its background colour only when no
  # theme is chosen (`Lemieux.TUI.start_link/1`), and `lmx` used to open it
  # with an empty harness, so a theme set in the config file was a theme the
  # screen did not know about until its session was ready: it asked anyway,
  # and drew its first frames in the guessed palette.
  #
  # Everything here goes through `TUI.opening_app/3`, the list `lmx` hands
  # the screen, rather than assembling that list again: a copy of the wiring
  # passes whatever the real one does.

  @moduletag :tmp_dir

  defp configured(dir, settings) do
    path = Path.join(dir, "config.json")
    File.write!(path, JSON.encode!(settings))
    assert {:ok, options} = Options.parse(["--config", path])
    options
  end

  defp opening(options, opts \\ []),
    do: TUI.opening_app(options, opts, size: {80, 24}, title: fn _text -> :ok end)

  # The screen as `lmx` opens it, before any session: `test_mode` draws to
  # a buffer, so no terminal is needed.
  defp opened(options, opts \\ []) do
    {:ok, screen} =
      Lemieux.TUI.start_link(opening(options, opts) ++ [test_mode: {80, 24}, name: nil])

    try do
      :sys.get_state(screen).user_state
    after
      GenServer.stop(screen)
    end
  end

  test "a theme from the config file is the screen's from its first frame", %{tmp_dir: dir} do
    options = configured(dir, %{"theme" => "light"})

    assert Keyword.fetch!(opening(options), :harness).theme == "light"
    assert opened(options).appearance.theme == Theme.light()
  end

  test "the config file's palettes come along, so one of them can open the screen",
       %{tmp_dir: dir} do
    sepia = Theme.dark() |> Theme.to_map() |> Map.put("name", "sepia")
    options = configured(dir, %{"theme" => "sepia", "themes" => %{"sepia" => sepia}})

    assert opened(options).appearance.theme.name == "sepia"
  end

  test "a host's theme wins over the config file's, as it does on the session's harness",
       %{tmp_dir: dir} do
    options = configured(dir, %{"theme" => "light"})

    assert Keyword.fetch!(opening(options, theme: "mono"), :harness).theme == "mono"
    assert opened(options, theme: "mono").appearance.theme == Theme.mono()
  end

  test "with no theme chosen the screen opens without one", %{tmp_dir: dir} do
    options = configured(dir, %{})

    assert Keyword.fetch!(opening(options), :harness).theme == nil
    assert opened(options).appearance.theme == nil
  end

  test "startup customization is available before asynchronous preparation", %{tmp_dir: dir} do
    settings = %{"options" => %{"text" => "HELLO LMX"}}
    options = configured(dir, %{"startup_animation" => settings})
    assert Keyword.fetch!(opening(options), :harness).startup_animation == settings
    assert opened(options).status.startup_animation["options"]["text"] == "HELLO LMX"
    assert opened(options, startup_animation: false).status.startup_animation == false
    path = Path.join(dir, "invalid.json")
    File.write!(path, JSON.encode!(%{"startup_animation" => %{"piece" => "File"}}))
    assert {:error, reason} = Options.parse(["--config", path])
    assert reason =~ "startup_animation"
  end

  # What `lmx` passes beside the harness is in the same list, so the screen
  # has them before any session.
  test "the host's fields and the runtime are in the list beside it", %{tmp_dir: dir} do
    options = configured(dir, %{"notifications" => false})
    app = opening(options)

    assert app[:size] == {80, 24}
    assert app[:config_path] == Path.join(dir, "config.json")
    assert app[:notifications] == false
  end
end
