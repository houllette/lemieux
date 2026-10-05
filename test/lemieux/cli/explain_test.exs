defmodule Lemieux.CLI.ExplainTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI

  @moduletag :tmp_dir

  # A personal config with nothing chosen: the model is lmx's to pick, the
  # way it is on a newcomer's machine.
  defp config(dir) do
    path = Path.join(dir, "config.json")
    File.write!(path, ~s({"version":1}))
    File.chmod!(path, 0o600)
    path
  end

  defp explain(argv, opts) do
    stdout =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> send(self(), {:result, CLI.run(argv, opts)}) end)
        send(self(), {:stderr, stderr})
      end)

    assert_received {:result, result}
    assert_received {:stderr, stderr}
    %{result: result, stdout: stdout, stderr: stderr}
  end

  # A local Ollama daemon, as Lemieux.CLI.Ollama asks it: `/api/tags` lists
  # what it serves and `/api/show` describes each tag. Tests never reach the
  # real daemon a developer may be running.
  defp daemon(names) do
    tags =
      Enum.map(names, &%{"name" => &1, "modified_at" => "2026-10-01T00:00:00Z", "details" => %{}})

    [
      get: fn url, _opts ->
        assert String.ends_with?(url, "/api/tags")
        {:ok, %Req.Response{status: 200, body: %{"models" => tags}}}
      end,
      post: fn url, _opts ->
        assert String.ends_with?(url, "/api/show")
        {:ok, %Req.Response{status: 200, body: %{"capabilities" => ["completion", "tools"]}}}
      end
    ]
  end

  # A daemon that must not be asked: the model is decided without it.
  defp unasked_daemon do
    [
      get: fn url, _opts -> flunk("explain asked Ollama (#{url}) for a model it was given") end,
      post: fn url, _opts -> flunk("explain asked Ollama (#{url}) for a model it was given") end
    ]
  end

  # `lmx run` and the terminal UI fall back to a model the local Ollama daemon
  # serves when no provider has a key; explain reported the keyless fallback
  # instead, on exactly the machines where run then answered with Ollama.
  test "reports the model lmx run would start on, a local Ollama one included", %{tmp_dir: dir} do
    result =
      explain(["explain", "--config", config(dir), "--no-delegate", "--no-project-mcp"],
        cwd: dir,
        env: %{},
        ollama: daemon(["llama3.2:latest"])
      )

    assert result.result == :ok
    diagnostics = JSON.decode!(result.stdout)["diagnostics"]
    assert diagnostics["model"] == "ollama:llama3.2:latest"
    assert diagnostics["model_source"] == "ollama"
  end

  test "a model somebody named is reported as named, without asking Ollama", %{tmp_dir: dir} do
    result =
      explain(
        ["explain", "--config", config(dir), "--model", "openai:gpt-6-sol", "--no-delegate"],
        cwd: dir,
        env: %{},
        ollama: unasked_daemon()
      )

    diagnostics = JSON.decode!(result.stdout)["diagnostics"]
    assert diagnostics["model"] == "openai:gpt-6-sol"
    assert diagnostics["model_source"] == "flag"
  end

  # `lmx run` keeps the configured model behind a gateway, which serves its
  # own names; explain used the terminal UI's rule and reported a local
  # Ollama model there instead.
  test "behind --base-url, the model lmx run would send to the gateway", %{tmp_dir: dir} do
    result =
      explain(
        [
          "explain",
          "--config",
          config(dir),
          "--base-url",
          "http://gateway.example/v1",
          "--no-delegate",
          "--no-project-mcp"
        ],
        cwd: dir,
        env: %{},
        ollama: unasked_daemon()
      )

    assert result.result == :ok
    diagnostics = JSON.decode!(result.stdout)["diagnostics"]
    refute diagnostics["model"] == "ollama:llama3.2:latest"
    assert diagnostics["model_source"] == "fallback"
  end

  # A session refuses a catalog with two tools of one name; explain said all
  # was well, so the planning example's duplicate `todo` stopped every session
  # while explaining it looked fine.
  test "a catalog with two tools of one name is an error, after the report", %{tmp_dir: dir} do
    result =
      explain(["explain", "--config", "none", "--no-delegate"],
        cwd: dir,
        tools: [Lemieux.Tools.Read, Lemieux.Tools.Read]
      )

    assert result.result == {:error, 1}
    assert %{"tools" => tools} = JSON.decode!(result.stdout)
    assert Enum.count(tools, &(&1["name"] == "read")) == 2
    assert result.stderr =~ "lmx explain: the tool catalog offers 2 tools named read"
    assert result.stderr =~ "a session would refuse to start"
  end

  test "a failure is a sentence, not an inspected term", %{tmp_dir: dir} do
    result = explain(["explain", "--config", Path.join(dir, "missing.json")], cwd: dir)

    assert result.result == {:error, 1}
    assert result.stderr =~ "lmx explain: The selected lmx configuration file does not exist."
    # `inspect/1` of the sentence used to print it in quotes.
    refute result.stderr =~ ~s(lmx explain: ")
  end
end
