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

  test "native hover defaults on in known terminals and falls back in unknown or multiplexed ones",
       %{
         tmp_dir: dir
       } do
    options = configured(dir, %{})

    for term <- ["xterm-ghostty", "xterm-kitty"] do
      env = %{"TERM" => term}
      assert opened(options, env: env).terminal.hover.enabled?

      for key <- ["TMUX", "STY", "ZELLIJ"] do
        value = if key == "ZELLIJ", do: "0", else: "active"
        refute opened(options, env: Map.put(env, key, value)).terminal.hover.enabled?
      end
    end

    for env <- [
          %{},
          %{"TERM" => "dumb"},
          %{"TERM" => "xterm-256color"},
          %{"TERM" => "screen-256color", "TERM_PROGRAM" => "ghostty"},
          %{"TERM" => "tmux-256color", "KITTY_WINDOW_ID" => "1"},
          %{"TERM" => "xterm-256color", "TERM_PROGRAM" => "ghostty"},
          %{"TERM" => "xterm-256color", "TERM_PROGRAM" => "iTerm.app"}
        ] do
      refute opened(options, env: env).terminal.hover.enabled?
    end
  end

  test "native hover can be disabled or explicitly declared for another terminal", %{tmp_dir: dir} do
    options = configured(dir, %{})
    env = %{"TERM" => "xterm-ghostty"}
    assert opened(options, env: env).terminal.hover.enabled?

    for value <- ["0", "false", "", "invalid"] do
      refute opened(options, env: Map.put(env, "LMX_HOVER_POINTER", value)).terminal.hover.enabled?
    end

    assert opened(options, env: %{"LMX_HOVER_POINTER" => "1"}).terminal.hover.enabled?

    assert opened(options, env: Map.merge(env, %{"TMUX" => "active", "LMX_HOVER_POINTER" => "1"})).terminal.hover.enabled?
  end

  test "automatic hover requires mouse capture and a local CLI transport", %{tmp_dir: dir} do
    options = configured(dir, %{})
    env = %{"TERM" => "xterm-ghostty"}
    assert opened(options, env: env).terminal.hover.enabled?

    for transport <- [:ssh, :session, :distributed, :cell_session, :unknown] do
      app = opening(options, [env: env], transport: transport)
      refute app[:hover_pointer]
    end

    options = put_in(options.host.mouse, false)
    refute opened(options, env: env).terminal.hover.enabled?
    refute opened(options, env: %{"LMX_HOVER_POINTER" => "1"}).terminal.hover.enabled?
  end

  test "session status titles are an optional boolean that reaches the running screen", %{
    tmp_dir: dir
  } do
    options = configured(dir, %{"program_status_title" => true})
    assert opening(options)[:program_status_title] == true
    assert opened(options).terminal.program_status_title?

    path = Path.join(dir, "config.json")
    File.write!(path, ~s({"program_status_title":"session"}))
    assert {:error, reason} = Options.parse(["--config", path])
    assert reason =~ "program_status_title"
    assert {:ok, default} = Options.parse(["--config", "none"])
    assert opening(default)[:program_status_title] == false
    refute opened(default).terminal.program_status_title?
  end

  defp opening(options, opts \\ [], runtime \\ []),
    do:
      TUI.opening_app(
        options,
        opts,
        Keyword.merge([size: {80, 24}, title: fn _text -> :ok end], runtime)
      )

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
