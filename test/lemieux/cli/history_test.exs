defmodule Lemieux.CLI.HistoryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)

    entries = [
      Entry.new(:user, %{"text" => "what is in the file?"}),
      Entry.new(:assistant, %{
        "content" => [%{"type" => "text", "text" => "let me look"}],
        "tool_calls" => [%{"id" => "t1", "name" => "read", "arguments" => %{"path" => "a.txt"}}]
      }),
      Entry.new(:tool_result, %{
        "call_id" => "t1",
        "name" => "read",
        "arguments" => %{"path" => "a.txt"},
        "output" => "alpha",
        "error" => false
      }),
      Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "it says alpha"}]})
    ]

    :ok = Store.append(store, "stored", entries)

    %{store: store, tmp_dir: tmp_dir, entries: entries}
  end

  defp lmx(argv, context, opts \\ []) do
    opts =
      Keyword.merge(
        [
          store: context.store,
          provider: Scripted.new([]),
          supervisor: :"lemieux_history_test_#{System.unique_integer([:positive])}"
        ],
        opts
      )

    argv = argv ++ ["--sessions-dir", context.tmp_dir]

    capture_io(fn ->
      capture_io(:stderr, fn -> send(self(), {:result, CLI.run(argv, opts)}) end)
    end)
  end

  describe "log" do
    test "renders a stored transcript", context do
      output = lmx(["log", "stored"], context)

      assert_received {:result, :ok}
      assert output =~ "what is in the file?"
      assert output =~ "it says alpha"
    end

    test "shows the tools that ran, not just what was said", context do
      output = lmx(["log", "stored"], context)

      assert output =~ "read"
      assert output =~ "alpha"
    end

    test "--jsonl preserves every durable entry for machine consumers", context do
      output = lmx(["log", "stored", "--jsonl"], context)

      decoded = output |> String.split("\n", trim: true) |> Enum.map(&Entry.decode!/1)
      assert decoded == context.entries
    end

    # The whole point of an owned transcript: reading it back costs nothing and
    # asks nobody.
    test "makes no request to any provider", context do
      provider = Scripted.new([])

      lmx(["log", "stored"], context, provider: provider)

      assert_received {:result, :ok}
      assert Scripted.requests(provider) == []
    end

    test "shows what the session was configured with", context do
      :ok =
        Store.append(context.store, "configured", [
          Entry.new(:session, %{
            "model" => "test:recorded",
            "system" => "be terse",
            "tools" => ["Elixir.Lemieux.Tools.Read"],
            "cwd" => "/tmp"
          })
        ])

      output = lmx(["log", "configured"], context)

      assert output =~ "test:recorded"
      assert output =~ "read"
    end

    test "an unknown session is an error on stderr", context do
      stdout = lmx(["log", "nope"], context)

      assert_received {:result, {:error, 1}}
      assert stdout == ""
    end

    test "log needs a session id", context do
      lmx(["log"], context)

      assert_received {:result, {:error, 1}}
    end
  end

  describe "request" do
    test "prints a canonical request entry as JSON", context do
      request =
        Entry.new(:request, %{
          "id" => "req-1",
          "kind" => "turn",
          "model" => "test:model",
          "entry_ids" => [],
          "tools" => [],
          "params" => %{},
          "sha256" => "abc"
        })

      :ok = Store.append(context.store, "requests", [request])
      output = lmx(["request", "requests", "req-1"], context)

      assert_received {:result, :ok}
      assert Entry.decode!(String.trim(output)) == request
    end
  end

  describe "fork" do
    test "prints the id of the new transcript", context do
      output = lmx(["fork", "stored"], context)

      assert_received {:result, :ok}

      id = String.trim(output)
      assert {:ok, entries} = Store.read(context.store, id)
      assert List.last(entries).type == :fork
    end

    # So `lmx fork ... | xargs lmx --resume` works: the id is the output, and
    # anything else lemieux wants to say belongs on stderr.
    test "the id is the only thing on stdout", context do
      output = lmx(["fork", "stored"], context)

      assert output |> String.trim() |> String.split("\n") |> length() == 1
    end

    test "--unsafe --at permits an explicitly chosen mid-turn entry", context do
      at = Enum.at(context.entries, 0).id

      output = lmx(["fork", "stored", "--at", at, "--unsafe"], context)
      id = String.trim(output)

      assert {:ok, entries} = Store.read(context.store, id)
      assert Enum.map(entries, & &1.type) == [:user, :fork]
    end

    test "a mid-turn cut is rejected by default", context do
      at = Enum.at(context.entries, 0).id

      stdout = lmx(["fork", "stored", "--at", at], context)

      assert_received {:result, {:error, 1}}
      assert stdout == ""
    end

    test "--at-turn selects a safe completed assistant turn", context do
      output = lmx(["fork", "stored", "--at-turn", "2"], context)
      id = String.trim(output)

      assert {:ok, entries} = Store.read(context.store, id)
      assert Enum.map(entries, & &1.type) == [:user, :assistant, :tool_result, :assistant, :fork]
    end

    test "an unknown cut point is an error, not a whole-transcript fork", context do
      stdout = lmx(["fork", "stored", "--at", "nope"], context)

      assert_received {:result, {:error, 1}}
      assert stdout == ""
    end

    test "forking an unknown session is an error", context do
      lmx(["fork", "nope"], context)

      assert_received {:result, {:error, 1}}
    end

    test "fork needs a session id", context do
      lmx(["fork"], context)

      assert_received {:result, {:error, 1}}
    end
  end

  describe "run --resume" do
    test "continues a stored transcript rather than starting a new one", context do
      provider = Scripted.new([[{:text_delta, "still alpha"}, {:done, :stop}]])

      lmx(["run", "--resume", "stored", "and now?"], context, provider: provider)

      assert_received {:result, :ok}

      assert [%{entries: entries}] = Scripted.requests(provider)
      assert length(entries) == 6
      assert List.last(entries).payload == %{"text" => "and now?"}
    end

    # The CLI always has a model to hand — its own default — so it must pass it
    # only when somebody actually asked for one, or every resume would quietly
    # switch the conversation's model.
    test "keeps the recorded model when --model is not given", context do
      :ok =
        Store.append(context.store, "configured", [
          Entry.new(:session, %{
            "model" => "test:recorded",
            "system" => "be terse",
            "tools" => [],
            "cwd" => "/tmp"
          })
        ])

      provider = Scripted.new([[{:done, :stop}]])
      # `--bare`, because `lmx run` now composes the repository's workspace
      # over a resumed session's prompt, as the terminal UI does; what this
      # test pins is the model, and the recorded prompt and tools with it.
      lmx(["run", "--bare", "--resume", "configured", "hi"], context, provider: provider)

      assert [%{model: "test:recorded", system: "be terse", tools: []}] =
               Scripted.requests(provider)
    end

    test "an explicit --model still wins", context do
      :ok =
        Store.append(context.store, "configured", [
          Entry.new(:session, %{
            "model" => "test:recorded",
            "system" => "be terse",
            "tools" => [],
            "cwd" => "/tmp"
          })
        ])

      provider = Scripted.new([[{:done, :stop}]])

      lmx(["run", "--resume", "configured", "--model", "test:asked-for", "hi"], context,
        provider: provider
      )

      assert [%{model: "test:asked-for"}] = Scripted.requests(provider)
    end

    test "resuming a session that does not exist is a usage error", context do
      lmx(["run", "--resume", "nope", "hello"], context)

      assert_received {:result, {:error, 2}}
    end
  end
end
