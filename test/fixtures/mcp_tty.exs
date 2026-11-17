# Real terminal rendering, with a scripted session and local process fixtures only.
[directory, server] = System.argv()
{:ok, _} = Application.ensure_all_started(:lemieux)
Logger.configure(level: :debug)
:ok = Lemieux.CLI.Logs.install(dir: directory, stderr?: true)
# A dependency/host can install a console handler after CLI configuration.
:ok =
  :logger.add_handler(:mcp_fixture_console, :logger_std_h, %{
    level: :debug,
    config: %{type: :standard_io}
  })

{:ok, _} = Lemieux.Supervisor.start_link()

{:ok, session} =
  Lemieux.start_session(
    provider: Lemieux.Providers.Scripted.new([]),
    model: "test:model",
    cwd: directory,
    store: Lemieux.Store.JSONL.new(Path.join(directory, "sessions"))
  )

results =
  for _restart <- 1..2 do
    Lemieux.CLI.TUI.quiet_stderr(
      fn ->
        {:ok, app} =
          Lemieux.TUI.start_link(
            name: nil,
            start: fn -> {:ok, session} end,
            background: :dark,
            colours: :truecolor,
            notify: fn _ -> :ok end,
            clipboard: fn _ -> :ok end,
            title: fn _ -> :ok end,
            program_status: fn _ -> :ok end
          )

        for char <- String.graphemes("preserve draft") do
          ExRatatui.Runtime.inject_event(app, %ExRatatui.Event.Key{
            code: char,
            kind: "press",
            modifiers: []
          })
        end

        ExRatatui.Runtime.inject_event(app, %ExRatatui.Event.Key{
          code: "left",
          kind: "press",
          modifiers: []
        })

        before = :sys.get_state(app).user_state
        cursor = ExRatatui.textarea_cursor(before.input)

        {:ok, config} =
          Lemieux.MCP.Transport.Stdio.configure(
            %{"name" => "ssh-fixture", "command" => "python3", "args" => [server]},
            cwd: directory
          )

        {:ok, transport} = Lemieux.MCP.Transport.Stdio.connect(config)
        capture = transport.diagnostics
        reader = :sys.get_state(capture).reader

        {:ok, %{"result" => %{"stderr_socket" => true}}, transport} =
          Lemieux.MCP.Transport.Stdio.call(transport, %{"id" => 1, "method" => "ping"}, 5_000)

        {:ok, %{"result" => result}, transport} =
          Lemieux.MCP.Transport.Stdio.call(
            transport,
            %{"id" => 2, "method" => "disconnect"},
            5_000
          )

        send(
          app,
          {:lemieux, before.id,
           {:mcp_server, %{name: "ssh-fixture", status: :failed, reason: "connection closed"}}}
        )

        ExRatatui.Runtime.inject_event(app, %ExRatatui.Event.Key{
          code: "right",
          kind: "release",
          modifiers: []
        })

        after_disconnect = :sys.get_state(app).user_state
        true = ExRatatui.textarea_cursor(after_disconnect.input) == cursor
        true = Lemieux.TUI.Composer.typed_value(after_disconnect) == "preserve draft"
        true = :sys.get_state(capture).remaining < 16_384
        :ok = Lemieux.MCP.Transport.Stdio.close(transport)
        false = Process.alive?(capture)
        false = Process.alive?(reader)
        GenServer.stop(app)
        result
      end,
      true
    )
  end

:ok = Lemieux.CLI.Logs.flush()
File.write!(Path.join(directory, "tty-results.json"), JSON.encode!(results))
