defmodule Lemieux.CLI.RunMissingKeyTest do
  # `lmx run`'s sentence for a start model with no key, end to end: through
  # option parsing, `Lemieux.CLI.Models` and the credential check that stops
  # a run before a session exists.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defp run(argv, env, dir) do
    store = JSONL.new(dir)

    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          send(
            self(),
            {:status,
             CLI.run(argv,
               store: store,
               supervisor: :"lemieux_run_missing_key_#{System.unique_integer([:positive])}",
               cwd: dir,
               env: env,
               stdin_terminal?: true
             )}
          )
        end)
      end)

    assert_received {:status, status}
    assert Store.list_sessions(store) == {:ok, []}
    {status, stderr}
  end

  # A reviewer's reproduction: `--config none` with OPENAI_API_KEY set said
  # "no model credentials found" and pointed at the terminal UI's panel and
  # a local Ollama, none of which a hermetic run uses.
  test "under --config none, a key for another provider is not 'no credentials'",
       %{tmp_dir: dir} do
    {status, stderr} = run(["run", "--config", "none", "hi"], %{"OPENAI_API_KEY" => "set"}, dir)

    assert status == {:error, 3}
    assert stderr =~ "--config none starts on anthropic:claude-sonnet-5"
    assert stderr =~ "ANTHROPIC_API_KEY"
    refute stderr =~ "no model credentials found"
  end

  test "a model the person named gets its own key's name, and no claim about /provider",
       %{tmp_dir: dir} do
    {status, stderr} =
      run(["run", "--config", "none", "--model", "openai:gpt-6-sol", "hi"], %{}, dir)

    assert status == {:error, 3}
    assert stderr =~ "no API key for openai: set OPENAI_API_KEY"
    refute stderr =~ "/provider"
  end
end
