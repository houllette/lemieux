defmodule Lemieux.CLI.DiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Lemieux.CLI
  alias Lemieux.Providers.ReqLLM, as: Provider

  @moduletag :tmp_dir

  test "explain reports presence and selected limits without credential or URL values", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "config.json")
    secret = "private-diagnostic-canary"

    File.write!(
      path,
      JSON.encode!(%{
        "model" => "openai:gpt-4o-mini",
        "providers" => %{"openai" => %{"api_key" => secret}},
        "base_url" => "https://gateway.example/private-path",
        "max_requests" => 4
      })
    )

    File.chmod!(path, 0o600)

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(["explain", "--config", path, "--no-project-mcp", "--no-delegate"],
                   provider: Provider.new()
                 )
      end)

    report = JSON.decode!(output)
    assert report["settings"]["max_requests"] == 4
    assert report["diagnostics"]["model"] == "openai:gpt-4o-mini"
    assert report["diagnostics"]["route"] == "provider_compatible_gateway"
    assert report["diagnostics"]["credentials"]["status"] == "present_not_verified"
    assert report["diagnostics"]["versions"]["lemieux"] == Lemieux.version()
    # What decides colour on the screen, so a report about a colourless one
    # shows whether `NO_COLOR` was inherited (the suite runs with it unset).
    assert %{"no_color" => "unset", "term" => _term, "colorterm" => _colorterm} =
             report["diagnostics"]["terminal"]

    refute output =~ secret
    refute output =~ "private-path"
    refute output =~ "gateway.example"
  end

  test "project MCP is explained without launching its command", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))
    path = Path.join(dir, ".mcp.json")
    File.write!(path, ~s({"mcpServers":{"unlaunched":{"command":"not-a-real-command"}}}))

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(["explain", "--config", "none", "--project-mcp", "--no-delegate"],
                   cwd: dir
                 )
      end)

    report = JSON.decode!(output)
    assert report["diagnostics"]["mcp"] == %{"file" => path, "servers" => ["unlaunched"]}
    assert Enum.any?(report["diagnostics"]["notices"], &String.contains?(&1, "execute commands"))
  end

  # Whether a repository's servers wait for trust is covered where the gate
  # is (Lemieux.CLI.RuntimeTest): this suite pins LMX_PROJECT_MCP=0.
  test "explain says what lmx turned on", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))
    config = Path.join(dir, "config.json")
    File.write!(config, ~s({"version":1,"credential_allowlist":["GH_TOKEN"]}))
    File.chmod!(config, 0o600)

    # An Ollama daemon that does not answer: explain asks the daemon as
    # `lmx run` does, and this machine's must not decide what the test sees.
    no_daemon = [
      get: fn _url, _opts -> {:error, %Req.TransportError{reason: :econnrefused}} end,
      post: fn _url, _opts -> flunk("nothing answered /api/tags, so nothing is described") end
    ]

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(["explain", "--config", config, "--no-delegate"],
                   cwd: dir,
                   ollama: no_daemon
                 )
      end)

    diagnostics = JSON.decode!(output)["diagnostics"]
    assert diagnostics["state_dir"] == dir
    assert diagnostics["permissions"] == %{"mode" => "off"}
    assert diagnostics["checkpoints"] == Path.join(dir, "checkpoints")
    assert diagnostics["subprocess_credentials"] == %{"scrubbed" => true, "allow" => ["GH_TOKEN"]}
    assert diagnostics["model_source"] in ~w(fallback credential last_used)
  end
end
