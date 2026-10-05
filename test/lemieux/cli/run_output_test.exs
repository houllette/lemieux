defmodule Lemieux.CLI.RunOutputTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  @hostile "Done. \e]52;c;cHduZWQ=\a\e]0;PWNED\a\e[31mred\e[0m\u009b2J end"

  setup %{tmp_dir: tmp_dir} do
    %{
      store: JSONL.new(tmp_dir),
      supervisor: :"lemieux_run_output_test_#{System.unique_integer([:positive])}"
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

  defp scripted(script), do: [provider: Scripted.new(script)]

  # `capture_io(:stderr, …)` captures the VM's standard error, which async
  # tests in other modules write to at the same time — their `lmx run`
  # lines, a compiler warning in colour. A refutation reads only the lines
  # this command could have written.
  defp lmx_lines(stderr) do
    stderr |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "lmx: "))
  end

  describe "text mode on a terminal" do
    test "the answer and the activity lines lose their escape sequences", context do
      call = %{id: "t1", name: "bash", arguments: %{"command" => "echo \e]0;TITLE\ahi"}}

      result =
        lmx(
          ["run", "go"],
          context,
          scripted([
            [{:tool_call, call}, {:done, :tool_calls}],
            [{:text_delta, @hostile}, {:done, :stop}]
          ]) ++ [terminal?: true]
        )

      assert result.status == :ok
      assert result.stdout == "Done. red2J end\n"
      assert "lmx: bash echo hi" in lmx_lines(result.stderr)

      for line <- lmx_lines(result.stderr) do
        refute line =~ "\e"
        refute line =~ "TITLE"
      end
    end

    test "redirected, the answer is the model's exact text", context do
      result =
        lmx(
          ["run", "go"],
          context,
          scripted([[{:text_delta, @hostile}, {:done, :stop}]]) ++ [terminal?: false]
        )

      assert result.stdout == @hostile <> "\n"
    end
  end

  describe "the JSON formats" do
    test "keep the exact text, and name the model the session ran on", context do
      result =
        lmx(
          ["run", "--output-format", "json", "--model", "test:chosen", "go"],
          context,
          scripted([[{:text_delta, @hostile}, {:done, :stop}]]) ++ [terminal?: true]
        )

      refute result.stdout =~ "\e"
      refute result.stdout =~ "\u009b"
      assert %{"text" => @hostile, "model" => "test:chosen"} = JSON.decode!(result.stdout)
    end

    test "stream-json names the model as the session starts", context do
      result =
        lmx(
          ["run", "--output-format", "stream-json", "--model", "test:chosen", "go"],
          context,
          scripted([[{:text_delta, "hi"}, {:done, :stop}]])
        )

      [session | _rest] =
        result.stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert %{"type" => "session", "model" => "test:chosen"} = session
      assert Map.has_key?(session, "context_window")
    end
  end

  describe "text mode's account of the run" do
    test "says what the prompt cost after the answer, on stderr", context do
      usage = %{"input_tokens" => 1200, "output_tokens" => 34, "cost_usd" => 0.0123}

      result =
        lmx(["run", "go"], context, scripted([Scripted.complete("answer", usage: usage)]))

      assert result.stdout == "answer\n"
      assert result.stderr =~ "lmx: usage: 1200 tokens in · 34 out · $0.0123"
    end

    test "says when nothing knows the model's context window", context do
      result = lmx(["run", "go"], context, scripted([Scripted.complete("answer")]))

      assert result.stderr =~ "context window"
      assert result.stderr =~ "--context-window N"
    end

    test "names the window when it is known", context do
      result =
        lmx(
          ["run", "--model", "test:windowed", "--context-window", "200000", "go"],
          context,
          scripted([Scripted.complete("answer")])
        )

      assert result.stderr =~ "test:windowed (200k-token window)"
      refute result.stderr =~ "nothing knows test:windowed's context window"
    end

    test "names the model on the session line", context do
      result =
        lmx(
          ["run", "--model", "test:chosen", "go"],
          context,
          scripted([Scripted.complete("answer")])
        )

      assert result.stderr =~ ~r/lmx: session \S+ · \S+ · test:chosen/
    end
  end

  # A long run that compacted, or could not, used to say nothing about it in
  # text mode; the shapes are the session's events (`Lemieux.Session`).
  describe "activity lines for the context window" do
    alias Lemieux.CLI.Run

    test "a compaction says how far it brought the conversation down" do
      assert Run.activity({:compacted, %{tokens: %{before: 91_000, after: 12_000}}}) ==
               "compacted the conversation: about 91000 → 12000 tokens"

      assert Run.activity({:compacted, %{tokens: nil}}) == "compacted the conversation"
    end

    test "a failed compaction says nothing was cut, in a sentence" do
      line = Run.activity({:compaction_failed, %Finch.TransportError{reason: :closed}})

      assert line =~ "compaction failed, so nothing was cut: "
      refute line =~ "%Finch"
    end

    test "an overflow says the request is being compacted and sent again" do
      assert Run.activity({:context_recovery, %{action: :compact_and_retry, reason: :overflow}}) =~
               "compacting once and sending it again"
    end

    test "an unknown window names the size compaction assumes, or that it is off" do
      assert Run.activity({:context_window_unknown, %{model: "ollama:x", fallback: 128_000}}) =~
               "nothing knows ollama:x's context window; compaction assumes 128000 tokens"

      assert Run.activity({:context_window_unknown, %{model: "ollama:x", fallback: nil}}) =~
               "never compacted on its own"
    end

    test "says nothing about an event it does not report" do
      assert Run.activity({:text_delta, %{text: "hi"}}) == nil
    end
  end

  describe "a model specification that cannot be resolved" do
    # It used to start a session, write a transcript and then fail the first
    # request with "gpt-4o is not a model I can reach: invalid_format".
    test "is a usage error before any session exists", context do
      result = lmx(["run", "--model", "gpt-4o", "hi"], context, env: %{})

      assert result.status == {:error, 2}
      assert result.stderr =~ "gpt-4o is not a model specification: write PROVIDER:MODEL"
      refute result.stderr =~ "invalid_format"
      # No session, so no transcript: the store, not the shared stderr, says so.
      assert Store.list_sessions(context.store) == {:ok, []}
    end

    test "an unknown provider is named", context do
      result = lmx(["run", "--model", "foo:bar", "hi"], context, env: %{})

      assert result.status == {:error, 2}
      assert result.stderr =~ "foo:bar names a provider lmx does not know (foo)"
      assert Store.list_sessions(context.store) == {:ok, []}
    end

    test "the JSON formats carry the same sentence and the model", context do
      result =
        lmx(["run", "--output-format", "json", "--model", "gpt-4o", "hi"], context, env: %{})

      assert %{
               "exit_status" => 2,
               "model" => "gpt-4o",
               "error" => %{"category" => "usage", "message" => message}
             } = JSON.decode!(result.stdout)

      assert message =~ "PROVIDER:MODEL"
    end

    test "from a source checkout, the help it points to is mix lmx's", context do
      result = lmx(["run", "--model", "gpt-4o", "hi"], context, env: %{}, program: "mix lmx")

      assert result.stderr =~ "(mix lmx help models)"
    end
  end

  describe "hints" do
    test "a missing prompt spells the command the way this lmx was started", context do
      result = lmx(["run"], context, program: "mix lmx")

      assert result.status == {:error, 2}
      assert result.stderr =~ ~s(mix lmx run "what should I do?")
    end

    test "resuming a session that does not exist names what was typed", context do
      result = lmx(["run", "--resume", "nothere", "hi"], context, scripted([]))

      assert result.status == {:error, 2}
      assert result.stderr =~ "no stored session has the id or name nothere"
      refute result.stderr =~ ":not_found"
    end
  end
end
