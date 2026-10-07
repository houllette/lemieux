defmodule Lemieux.CLI.RunTextsTest do
  # What `lmx run` says on stderr beside the answer: the context window once,
  # with the right advice for a local model; what the configuration had to
  # say before a refusal; what `/undo` will not cover; and a cut-off answer
  # in a sentence.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.Run
  alias Lemieux.CLI.State
  alias Lemieux.Conversation
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  @undo_note "lmx: /undo covers file-tool edits only here: not a git repository, " <>
               "so what commands change is not recorded"

  setup %{tmp_dir: tmp_dir} do
    %{
      store: JSONL.new(Path.join(tmp_dir, "sessions")),
      supervisor: :"lemieux_run_texts_#{System.unique_integer([:positive])}"
    }
  end

  defp lmx(argv, context, extra) do
    opts =
      Keyword.merge(
        [
          store: context.store,
          supervisor: context.supervisor,
          cwd: context.tmp_dir,
          stdin_terminal?: true
        ],
        extra
      )

    stdout =
      capture_io(fn ->
        capture_io(:stderr, fn -> send(self(), {:status, CLI.run(argv, opts)}) end)
        |> then(&send(self(), {:stderr, &1}))
      end)

    assert_received {:status, status}
    assert_received {:stderr, stderr}
    %{status: status, stdout: stdout, stderr: stderr}
  end

  # Standard error is the VM's, which async tests in other modules write to
  # at the same time; these are the lines an `lmx run` could have written.
  defp lmx_lines(stderr),
    do: stderr |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "lmx: "))

  defp scripted(script), do: [provider: Scripted.new(script)]

  defp outside(_context) do
    dir = Path.join(System.tmp_dir!(), "lmx-run-texts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{outside: dir}
  end

  describe "the context window" do
    # The session says so before the model's first request, and `lmx run`
    # hears it there; saying it at the start as well printed two lines, the
    # first guessing what the second knew.
    test "an unknown window is said once, with the size compaction assumes", context do
      result =
        lmx(["run", "--model", "test:once", "go"], context, scripted([Scripted.complete("ok")]))

      assert [line] =
               result.stderr
               |> lmx_lines()
               |> Enum.filter(&(&1 =~ "nothing knows test:once's context window"))

      assert line =~ "compaction assumes 128000 tokens (--context-window N says"
    end

    test "for an Ollama model the advice is the server's window, not --context-window" do
      for fallback <- [128_000, nil] do
        line =
          Run.activity({:context_window_unknown, %{model: "ollama:qwen3.8", fallback: fallback}})

        assert line =~ "until Ollama reports the window it serves"
        assert line =~ "set OLLAMA_CONTEXT_LENGTH to 32768 or more for the Ollama server"
        assert line =~ "`ollama ps` shows the window once the model is loaded"
        refute line =~ "--context-window"
      end
    end

    test "a window too small to work in, and a summary that made no room, have lines" do
      small = %{model: "ollama:gemma4:12b", window: 4_096, overhead: 3_490, source: :served}
      ineffective = %{input_tokens: 90_000, threshold: 80_000, window: 100_000, retry_in: 32}

      assert Run.activity({:context_window_small, small}) == Conversation.small_window(small)

      assert Run.activity({:compaction_ineffective, ineffective}) ==
               Conversation.ineffective_compaction(ineffective)

      refute Run.activity({:compaction_ineffective, ineffective}) =~ "/compact"
    end

    test "stream-json carries them as notices", context do
      result =
        lmx(
          ["run", "--output-format", "stream-json", "--model", "test:stream", "go"],
          context,
          scripted([Scripted.complete("ok")])
        )

      events = result.stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert Enum.any?(
               events,
               &match?(
                 %{
                   "type" => "notice",
                   "text" => "nothing knows test:stream's context window" <> _
                 },
                 &1
               )
             )

      assert List.last(events)["type"] == "result"
    end
  end

  describe "a refusal before any session" do
    # The reviewer's case: the model the person last chose is a local one,
    # Ollama is not running and no key is set. The refusal said "no model
    # credentials found" alone; the notice that explained why it was looking
    # for a key at all was never printed.
    setup %{tmp_dir: tmp_dir} do
      config = Path.join(tmp_dir, "config.json")
      File.write!(config, ~s({"version": 1}\n))
      :ok = State.remember_model(tmp_dir, "ollama:llama3.2", chosen?: true)
      %{config: config}
    end

    defp unreachable, do: [get: fn _url, _opts -> {:error, :econnrefused} end]

    test "says what the configuration had to say first", context do
      result =
        lmx(["run", "--config", context.config, "hi"], context, env: %{}, ollama: unreachable())

      assert result.status == {:error, 3}
      lines = lmx_lines(result.stderr)

      warning =
        Enum.find_index(
          lines,
          &(&1 =~ "ollama:llama3.2, the model you last chose, is not available")
        )

      refusal = Enum.find_index(lines, &(&1 =~ "no model credentials found"))

      assert is_integer(warning) and is_integer(refusal)
      assert warning < refusal
      assert Store.list_sessions(context.store) == {:ok, []}
    end

    test "stream-json gets the warning as a notice before the result", context do
      result =
        lmx(["run", "--output-format", "stream-json", "--config", context.config, "hi"], context,
          env: %{},
          ollama: unreachable()
        )

      assert [%{"type" => "notice", "text" => notice}, %{"type" => "result"}] =
               result.stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert notice =~ "the model you last chose, is not available"
    end

    test "the missing-key sentence spells the help command the way it can be typed", context do
      result =
        lmx(["run", "--config", "none", "hi"], context, env: %{}, program: "mix lmx")

      assert result.status == {:error, 3}
      assert result.stderr =~ "(mix lmx help models lists them)"
    end
  end

  describe "what /undo will not cover" do
    setup [:outside]

    setup %{tmp_dir: tmp_dir} do
      config = Path.join(tmp_dir, "config.json")
      File.write!(config, ~s({"version": 1}\n))

      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      {_output, 0} = System.cmd("git", ["init", "-q"], cd: repo, stderr_to_stdout: true)

      %{config: config, repo: repo}
    end

    defp two_commands do
      call = fn id, command -> %{id: id, name: "bash", arguments: %{"command" => command}} end

      scripted([
        [{:tool_call, call.("c1", "echo one")}, {:done, :tool_calls}],
        [{:tool_call, call.("c2", "echo two")}, {:done, :tool_calls}],
        Scripted.complete("done")
      ])
    end

    test "outside a git repository the first command says so, once", context do
      result =
        lmx(
          ["run", "--config", context.config, "go"],
          context,
          [cwd: context.outside] ++ two_commands()
        )

      assert result.status == :ok
      lines = lmx_lines(result.stderr)

      assert Enum.count(lines, &(&1 == @undo_note)) == 1

      assert Enum.find_index(lines, &(&1 == "lmx: bash echo one")) <
               Enum.find_index(lines, &(&1 == @undo_note))
    end

    test "in a git repository commands are recorded, and nothing is said", context do
      result =
        lmx(
          ["run", "--config", context.config, "go"],
          context,
          [cwd: context.repo] ++ two_commands()
        )

      assert result.status == :ok
      refute Enum.any?(lmx_lines(result.stderr), &(&1 =~ "/undo"))
    end

    # `--config none` keeps no state, so nothing is recorded at all and there
    # is no /undo for the note to qualify.
    test "with checkpoints off there is nothing to say", context do
      result =
        lmx(["run", "--config", "none", "go"], context, [cwd: context.outside] ++ two_commands())

      assert result.status == :ok
      refute Enum.any?(lmx_lines(result.stderr), &(&1 =~ "/undo"))
    end

    test "a run that only answers hears nothing about it", context do
      result =
        lmx(["run", "--config", context.config, "go"], context,
          cwd: context.outside,
          provider: Scripted.new([Scripted.complete("just an answer")])
        )

      refute Enum.any?(lmx_lines(result.stderr), &(&1 =~ "/undo"))
    end
  end

  describe "an answer the output cap ended" do
    # `Lemieux.Extensions.Continuation` picks up the first cut-off on its own;
    # the second, with nothing done in between, is the one that ends the run.
    defp cut_off_twice,
      do: [
        Scripted.complete("partial", finish_reason: :length),
        Scripted.complete("still partial", finish_reason: :length)
      ]

    test "keeps the partial answer, fails, and says how to have it carry on", context do
      result = lmx(["run", "work"], context, scripted(cut_off_twice()))

      assert result.status == {:error, 1}
      assert result.stdout == "still partial\n"

      assert result.stderr =~
               ~r/lmx: the answer did not complete: it was cut off at the model's output limit; lmx run --resume \S+ continue picks up where it stopped/

      refute result.stderr =~ ":length"
    end

    test "from a source checkout the way on says mix lmx", context do
      result =
        lmx(
          ["run", "work"],
          context,
          [program: "mix lmx"] ++ scripted(cut_off_twice())
        )

      assert result.stderr =~ ~r/mix lmx run --resume \S+ continue/
    end
  end
end
