defmodule Lemieux.CLI.HistoryLogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{store: JSONL.new(tmp_dir), tmp_dir: tmp_dir}
  end

  defp lmx(argv, context, opts \\ []) do
    opts =
      Keyword.merge(
        [
          store: context.store,
          provider: Scripted.new([]),
          supervisor: :"lemieux_history_log_test_#{System.unique_integer([:positive])}"
        ],
        opts
      )

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn -> send(self(), {:result, CLI.run(argv, opts)}) end)

        send(self(), {:stderr, stderr})
      end)

    assert_received {:result, result}
    assert_received {:stderr, stderr}
    %{result: result, stdout: stdout, stderr: stderr}
  end

  describe "the header" do
    # The session entry stores module names, which is what restores; the
    # model was offered what the first request says.
    test "names the tools the first request offered", context do
      :ok =
        Store.append(context.store, "offered", [
          Entry.new(:session, %{
            "model" => "test:recorded",
            "tools" => ["Elixir.Lemieux.Tools.Read", "Elixir.Lemieux.Extensions.Planning.Tool"]
          }),
          Entry.new(:user, %{"text" => "plan it"}),
          Entry.new(:request, %{
            "id" => "req-1",
            "model" => "test:recorded",
            "tools" => [%{"name" => "read"}, %{"name" => "todo"}, %{"name" => "bash"}]
          }),
          Entry.new(:request, %{
            "id" => "req-2",
            "model" => "test:recorded",
            "tools" => [%{"name" => "read"}]
          })
        ])

      output = lmx(["log", "offered", "--sessions-dir", context.tmp_dir], context).stdout

      assert output =~ "— test:recorded, tools: read, todo, bash —"
      refute output =~ ", tool —"
    end

    # A `/model` switch or a resume with other tools appends a new session
    # entry; each header names what was offered under it, not the first
    # request's tools all over again.
    test "each header names the tools of the requests that followed it", context do
      :ok =
        Store.append(context.store, "switched", [
          Entry.new(:session, %{"model" => "test:first", "tools" => []}),
          Entry.new(:request, %{
            "id" => "req-1",
            "model" => "test:first",
            "tools" => [%{"name" => "read"}]
          }),
          Entry.new(:session, %{"model" => "test:second", "tools" => []}),
          Entry.new(:session, %{
            "model" => "test:third",
            "tools" => ["Elixir.Lemieux.Tools.Read"]
          }),
          Entry.new(:request, %{
            "id" => "req-2",
            "model" => "test:third",
            "tools" => [%{"name" => "read"}, %{"name" => "edit"}]
          })
        ])

      output = lmx(["log", "switched", "--sessions-dir", context.tmp_dir], context).stdout

      assert output =~ "— test:first, tools: read —"
      # No request ran under it: what the entry itself recorded.
      assert output =~ "— test:second, tools: none —"
      assert output =~ "— test:third, tools: read, edit —"
    end

    test "without a request, the recorded modules' short names", context do
      :ok =
        Store.append(context.store, "quiet", [
          Entry.new(:session, %{
            "model" => "test:recorded",
            "tools" => ["Elixir.Lemieux.Tools.Read"]
          })
        ])

      assert lmx(["log", "quiet", "--sessions-dir", context.tmp_dir], context).stdout =~
               "tools: read —"
    end
  end

  describe "on a terminal" do
    setup %{store: store} do
      hostile = "here \e]52;c;cHduZWQ=\a and \e[31mred\e[0m \e]0;title\a"

      :ok =
        Store.append(store, "hostile", [
          Entry.new(:user, %{"text" => "hi"}),
          Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => hostile}]})
        ])

      %{hostile: hostile}
    end

    test "prints what the model said without its escape sequences", context do
      output =
        lmx(["log", "hostile", "--sessions-dir", context.tmp_dir], context, terminal?: true).stdout

      refute output =~ "\e"
      refute output =~ "\a"
      assert output =~ "agent: here  and red"
    end

    test "redirected, the text is exact", context do
      output =
        lmx(["log", "hostile", "--sessions-dir", context.tmp_dir], context, terminal?: false).stdout

      assert output =~ context.hostile
    end

    test "--jsonl keeps the exact text a decoder reads back", context do
      output =
        lmx(["log", "hostile", "--sessions-dir", context.tmp_dir, "--jsonl"], context,
          terminal?: true
        ).stdout

      [_user, assistant] = output |> String.split("\n", trim: true) |> Enum.map(&Entry.decode!/1)
      assert [%{"text" => text}] = assistant.payload["content"]
      assert text == context.hostile
    end
  end

  describe "errors" do
    test "an unknown session is a sentence naming what was typed", context do
      result = lmx(["log", "nothere", "--sessions-dir", context.tmp_dir], context)

      assert result.result == {:error, 1}
      assert result.stderr =~ "no stored session has the id or name nothere"
      assert result.stdout == ""
    end

    test "a missing id spells the command the way this lmx was started", context do
      result = lmx(["log", "--sessions-dir", context.tmp_dir], context, program: "mix lmx")

      assert result.stderr =~ "mix lmx log SESSION"
    end
  end
end
