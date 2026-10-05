defmodule Lemieux.Conversation.DispatchTest do
  @moduledoc """
  The effects both front ends perform the same way, performed against a real
  session by a host that only records what it was asked to do.

  The host here is the smallest thing that satisfies `Lemieux.Conversation.Dispatch.t/0`:
  its state is a conversation plus a list of calls, newest first. Work that
  may block is run inline by default, and one test hands
  over a recorder instead to check the TUI's shape, where the answer comes
  back later through `answer/3`.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Conversation.Command.Deny
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Environment.Local
  alias Lemieux.Eval.Attach
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Echo do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl Lemieux.Tool
    def name, do: "echo"
    @impl Lemieux.Tool
    def description, do: "Echoes what it is given."
    @impl Lemieux.Tool
    def schema, do: %{"type" => "object", "properties" => %{}}
    @impl Lemieux.Tool
    def run(%{"say" => say}, _context), do: {:ok, "echo: #{say}"}
    @impl Lemieux.Tool
    def parallel_safe?, do: true
  end

  # A host's own command, performed through the dispatcher like a built-in.
  defmodule Wave do
    @moduledoc false
    @behaviour Lemieux.Conversation.Command

    @impl Lemieux.Conversation.Command
    def spec,
      do: %{name: "wave", description: "wave", accepts_arguments?: true, action: {:wave, nil}}

    @impl Lemieux.Conversation.Command
    def parse(whom, _conversation), do: [{:wave, String.trim(whom)}]

    @impl Lemieux.Conversation.Command
    def perform(acc, host, {:wave, whom}), do: Dispatch.say(acc, host, "waved at #{whom}")
  end

  defmodule Ledger do
    @moduledoc false

    def anchors(%{entries: entries}), do: Enum.map(entries, & &1.id)

    def capture(submission, opts) do
      send(Keyword.fetch!(opts, :test), {:captured, submission})
      {:ok, %{id: "fb-1"}}
    end

    def harvest(%{id: id}, _opts), do: {:ok, ["opportunity-for-#{id}"]}
  end

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_dispatch_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start(context, script, opts \\ []) do
    provider = Scripted.new(script)

    {:ok, session} =
      Lemieux.start_session(
        Keyword.merge(
          [
            supervisor: context.runtime,
            provider: provider,
            store: context.store,
            model: "test:model",
            subscriber: self()
          ],
          opts
        )
      )

    {session, provider}
  end

  # One answered turn, so there is a transcript to copy, clear and anchor to.
  defp answered(context) do
    {session, provider} = start(context, [Scripted.complete("hi back")])
    :ok = Session.prompt(session, "hello")
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

    {session, provider}
  end

  defp acc, do: %{conversation: Conversation.new(model: "test:model"), calls: []}

  defp record(acc, call), do: %{acc | calls: [call | acc.calls]}

  defp calls(acc), do: Enum.reverse(acc.calls)

  defp said(acc), do: for({:say, text} <- calls(acc), do: text)

  # Built on every use rather than once, because the callbacks that run work
  # inline need a host to hand the answer to, and that host is this one.
  defp host(session, opts \\ []) do
    test = self()

    Dispatch.new(
      [
        session: session,
        id: session && Session.id(session),
        say: fn acc, text -> record(acc, {:say, text}) end,
        write: fn acc, text -> record(acc, {:write, text}) end,
        fold: fn acc, event -> fold(acc, event, session, opts) end,
        run:
          Keyword.get(opts, :run, fn acc, work ->
            Dispatch.answer(acc, host(session, opts), work.())
          end),
        react: fn acc, reaction -> record(acc, {:react, reaction}) end,
        clipboard:
          Keyword.get(opts, :clipboard, fn text ->
            send(test, {:clipboard, text})
            :ok
          end),
        discovered: Keyword.get(opts, :discovered, []),
        feedback: Ledger,
        feedback_opts: [test: test]
      ] ++
        Keyword.take(opts, [
          :commands,
          :environment,
          :cwd,
          :permissions,
          :checkpoints,
          :export_dir,
          :personal_dir
        ])
    )
  end

  # What every real host does with an answer: fold it through the conversation
  # and perform what comes back, through the same dispatcher.
  defp fold(acc, event, session, opts) do
    {conversation, effects} = Conversation.event(acc.conversation, event)
    acc = record(%{acc | conversation: conversation}, {:fold, event})

    Enum.reduce(effects, acc, &Dispatch.perform(&2, host(session, opts), &1))
  end

  # A host that does not run work, only keeps it — the TUI's shape, where a
  # task runs it and the answer arrives later as a message.
  defp deferring(session, opts \\ []) do
    host(session, [run: fn acc, work -> record(acc, {:run, work}) end] ++ opts)
  end

  defp deferred(acc) do
    case Enum.find(calls(acc), &match?({:run, _work}, &1)) do
      {:run, work} -> work.()
      nil -> flunk("no work was handed to the host")
    end
  end

  describe "text" do
    test "say and write go to the host's own callbacks", context do
      {session, _provider} = start(context, [])

      acc =
        acc()
        |> Dispatch.perform(host(session), {:say, "a line"})
        |> Dispatch.perform(host(session), {:write, "a frag"})

      assert calls(acc) == [{:say, "a line"}, {:write, "a frag"}]
    end

    test "what a terminal does with :ready, :idle and a question is the host's business",
         context do
      {session, _provider} = start(context, [])
      before = acc()

      for effect <- [:ready, :idle, {:asked, %{call_id: "q", question: "?"}}] do
        assert Dispatch.perform(before, host(session), effect) == before
      end
    end
  end

  describe "the turn" do
    test "a prompt reaches the session and the host hears that a turn started", context do
      {session, provider} = start(context, [Scripted.complete("hi back")])

      acc = Dispatch.perform(acc(), host(session), {:prompt, "hello"})

      assert calls(acc) == [{:react, :turn_started}]
      id = Session.id(session)
      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000
      assert [request] = Scripted.requests(provider)
      assert Enum.any?(request.entries, &(&1.type == :user))
    end

    test "a steer reaches the running turn and the host hears that it landed", context do
      gate = self()

      script = [
        fn _request ->
          send(gate, {:turn, self()})

          receive do
            :release -> [{:done, :stop}]
          after
            5_000 -> [{:done, :stop}]
          end
        end,
        [{:done, :stop}]
      ]

      {session, _provider} = start(context, script)
      :ok = Session.prompt(session, "take your time")
      assert_receive {:turn, turn}, 5_000

      acc = Dispatch.perform(acc(), host(session), {:steer, "faster"})

      assert calls(acc) == [{:react, :steered}]
      send(turn, :release)

      # To the end of the turn: one that outlived the test lost its scripted
      # provider mid-request, and logged the crash where nothing captured it.
      id = Session.id(session)
      assert_receive {:lemieux, ^id, {:finished, _reason}}
    end

    test "cancel stops the turn without a word of its own", context do
      gate = self()

      script = [
        fn _request ->
          send(gate, {:turn, self()})

          receive do
            :never -> [{:done, :stop}]
          after
            5_000 -> [{:done, :stop}]
          end
        end
      ]

      {session, _provider} = start(context, script)
      :ok = Session.prompt(session, "take your time")
      assert_receive {:turn, _turn}, 5_000

      acc = Dispatch.perform(acc(), host(session), :cancel)

      assert calls(acc) == []
      id = Session.id(session)
      assert_receive {:lemieux, ^id, {:finished, :cancelled}}, 5_000
    end

    test "an accepted retry is a turn starting; a refused one is only a line", context do
      {session, _provider} = start(context, [])

      refused = Dispatch.perform(acc(), host(session), :retry)

      assert said(refused) == ["nothing failed, so there is nothing to retry"]
      refute {:react, :turn_started} in calls(refused)

      accepted = Dispatch.answer(acc(), host(session), {:retry_result, :ok})

      assert accepted.conversation.busy?
      assert {:react, :turn_started} in calls(accepted)
    end
  end

  describe "work that may block" do
    test "compaction is run and its answer folded back through the conversation", context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), host(session), :compact)

      assert {:fold, {:compaction_result, {:error, :nothing_to_do}}} in calls(acc)
      assert said(acc) == ["nothing worth summarising yet"]
    end

    test "a host that defers the work gets the same answer later", context do
      {session, _provider} = start(context, [])

      started = Dispatch.perform(acc(), deferring(session), :compact)
      assert said(started) == []

      answer = deferred(started)
      assert {:compaction_result, {:error, :nothing_to_do}} = answer

      done = Dispatch.answer(started, deferring(session), answer)
      assert said(done) == ["nothing worth summarising yet"]
    end

    test "refresh answers through the same path", context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), host(session), :refresh)

      assert said(acc) == ["every attached file is current"]
    end

    test "reflecting marks the conversation busy before the model is asked", context do
      {session, _provider} = start(context, [Scripted.complete("Consider a test.")])

      acc = Dispatch.perform(acc(), deferring(session), {:reflect, :assessment})

      assert acc.conversation.busy?
      assert {:fold, {:reflection_started, :assessment}} in calls(acc)
      assert {:react, {:reflecting, :assessment}} in calls(acc)
      assert deferred(acc) == {:reflection_result, :ok}

      # The reflection runs on as a turn of its own; see the steer test above.
      id = Session.id(session)
      assert_receive {:lemieux, ^id, {:finished, _reason}}
    end
  end

  describe "model, provider and effort" do
    test "a model switch is reported to the host, and a refused one to the person", context do
      {session, _provider} = start(context, [])

      switched = Dispatch.perform(acc(), host(session), {:set_model, "test:other"})
      assert calls(switched) == [{:react, {:model_set, "test:other"}}]
    end

    test "a switch the session refuses is said, not reacted to", context do
      gate = self()

      script = [
        fn _request ->
          send(gate, {:turn, self()})

          receive do
            :release -> [{:done, :stop}]
          after
            5_000 -> [{:done, :stop}]
          end
        end
      ]

      {session, _provider} = start(context, script)
      :ok = Session.prompt(session, "take your time")
      assert_receive {:turn, turn}, 5_000

      refused = Dispatch.perform(acc(), host(session), {:set_model, "test:other"})

      assert [line] = said(refused)
      assert line =~ "could not switch model"
      refute Enum.any?(calls(refused), &match?({:react, _}, &1))
      send(turn, :release)
    end

    test "a provider is normalised before the session sees it", context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), host(session), {:set_provider, " TEST "})

      assert [{:react, {:provider_set, "test:" <> _model}}] = calls(acc)
    end

    test "a provider the session cannot reach falls back to what the host discovered",
         context do
      {session, _provider} = start(context, [])

      unknown = Dispatch.perform(acc(), host(session), {:set_provider, "ghost"})

      assert said(unknown) == [
               "could not switch provider: ghost has no available models for this session"
             ]

      found =
        Dispatch.perform(
          acc(),
          host(session, discovered: ["other:model", "ghost:local"]),
          {:set_provider, "ghost"}
        )

      assert calls(found) == [{:react, {:provider_set, "ghost:local"}}]
    end

    test "an unsupported reasoning effort is explained", context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), host(session), {:set_reasoning_effort, "extreme"})

      assert [line] = said(acc)
      assert line =~ "could not set reasoning effort"
    end
  end

  describe "tools and MCP" do
    test "the tool listing goes to the host's catalog and to the conversation", context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), host(session), :tools_status)

      assert [
               {:react, {:tool_statuses, statuses}},
               {:fold, {:tools_status, statuses}},
               {:say, listing}
             ] =
               calls(acc)

      assert Enum.any?(statuses, &(&1.name == "read"))
      assert listing =~ "read · local · enabled"
    end

    test "changing tool access tells the host its catalog is stale", context do
      {session, _provider} = start(context, [])

      changed = Dispatch.perform(acc(), host(session), {:disable_tools, ["read"]})
      assert calls(changed) == [{:react, :tools_changed}]

      refused = Dispatch.perform(acc(), host(session), {:enable_tools, ["ghost"]})
      assert [line] = said(refused)
      assert line =~ "could not change tools"
    end

    test "the MCP listing goes to the host's catalog and to the conversation", context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), host(session), :mcp_status)

      assert {:react, {:mcp_statuses, []}} in calls(acc)
      assert said(acc) == ["no MCP servers configured · /mcp add PATH"]
    end

    test "an MCP change is announced to the host, run, and its failure reported", context do
      {session, _provider} = start(context, [])
      missing = Path.join(context.tmp_dir, "no-such-servers.json")

      acc = Dispatch.perform(acc(), host(session), {:mcp_add, missing})

      assert List.first(calls(acc)) == {:react, {:mcp_started, "add"}}
      assert [line] = said(acc)
      assert line =~ "MCP:"
      refute Enum.any?(calls(acc), &match?({:react, {:mcp_statuses, _}}, &1))
    end

    test "a successful MCP change is followed by a fresh listing for the host and the person",
         context do
      {session, _provider} = start(context, [])
      statuses = [%{name: "github", transport: :stdio, tool_count: 3}]

      acc = Dispatch.answer(acc(), host(session), {:mcp_result, "add", :ok, statuses})

      assert calls(acc) == [
               {:fold, {:mcp_result, "add", :ok}},
               {:say, "MCP add complete"},
               {:react, {:mcp_statuses, statuses}},
               {:react, :tools_changed},
               {:fold, {:mcp_status, statuses}},
               {:say, "github · stdio · 3 tools"}
             ]
    end
  end

  describe "feedback" do
    test "anchors are read from the session and handed back as an answer", context do
      {session, _provider} = answered(context)

      acc = Dispatch.perform(acc(), deferring(session), :feedback)

      assert {:feedback_anchors, anchors} = deferred(acc)
      refute anchors == []
    end

    test "a submission is written under this session's id", context do
      {session, _provider} = start(context, [])
      id = Session.id(session)

      acc = Dispatch.perform(acc(), deferring(session), {:feedback, %{raw_text: "slower"}})

      assert deferred(acc) == {:feedback_result, {:ok, "fb-1"}}
      assert_receive {:captured, %{raw_text: "slower", session_id: ^id}}
    end

    test "mining reads the snapshot now and harvests later", context do
      {session, _provider} = start(context, [])
      id = Session.id(session)

      acc = Dispatch.perform(acc(), deferring(session), :mine_opportunities)

      assert deferred(acc) == {:opportunities_result, {:ok, ["opportunity-for-#{id}"]}}
    end
  end

  describe "copy" do
    test "the latest answer goes to the host's clipboard", context do
      {session, _provider} = answered(context)

      acc = Dispatch.perform(acc(), host(session), :copy)

      assert_receive {:clipboard, "hi back"}
      assert said(acc) == ["copied the latest agent response"]
    end

    test "nothing to copy, and no clipboard to copy to, are both said", context do
      {session, _provider} = start(context, [])

      assert said(Dispatch.perform(acc(), host(session), :copy)) == ["no agent response to copy"]
      assert said(Dispatch.perform(acc(), host(nil), :copy)) == ["no agent response to copy"]

      {answered, _provider} = answered(context)
      unsupported = host(answered, clipboard: fn _text -> {:error, :unsupported_transport} end)

      assert said(Dispatch.perform(acc(), unsupported, :copy)) ==
               ["clipboard copy is unavailable for this terminal transport"]

      broken = host(answered, clipboard: fn _text -> {:error, :closed} end)

      assert said(Dispatch.perform(acc(), broken, :copy)) ==
               ["could not copy the latest agent response: :closed"]
    end
  end

  describe "attaching" do
    test "with no target it offers rather than picks", context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), host(session, commands: Builtin.elixir()), {:attach, nil})

      assert said(acc) == [Attach.offer()]
    end

    # Reached through the session's own evaluation node, which the session
    # itself knows nothing about: only the runtime it is mounted in.
    test "detaching goes back to the session's own node", context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), host(session, commands: Builtin.elixir()), :detach)

      assert said(acc) == ["back on this session's own node"]
      assert Lemieux.Eval.attached(session) == nil
    end

    # `/attach` belongs to the Elixir tooling: a host that did not offer it
    # does not perform it.
    test "are not performed by a host whose registry does not offer them", context do
      {session, _provider} = start(context, [])

      assert calls(Dispatch.perform(acc(), host(session), {:attach, nil})) == []
    end
  end

  describe "a tool call waiting for approval" do
    defp parked(context) do
      script = [
        [
          {:tool_call, %{id: "t1", name: "echo", arguments: %{"say" => "hello"}}},
          {:done, :tool_calls}
        ],
        [{:text_delta, "done"}, {:done, :stop}]
      ]

      {session, provider} =
        start(context, script,
          tools: [Echo],
          hooks: [before_tool_call: fn _call, _context -> :pending end]
        )

      :ok = Session.prompt(session, "use the tool")
      id = Session.id(session)
      assert_receive {:lemieux, ^id, {:tool_approval, _call}}, 5_000

      {session, provider, id}
    end

    defp tool_result(provider) do
      assert [_first, %{entries: entries}] = Scripted.requests(provider)
      %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      payload
    end

    test "approving runs it, and the session's answer is folded back", context do
      {session, provider, id} = parked(context)

      acc = Dispatch.perform(acc(), host(session), {:approve, "t1"})

      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000
      assert %{"output" => "echo: hello", "error" => false} = tool_result(provider)
      assert {:fold, {:approval_result, "t1", :ok}} in calls(acc)
      assert said(acc) == []
    end

    test "denying refuses it, and the reason is what the model reads", context do
      {session, provider, id} = parked(context)

      Dispatch.perform(acc(), host(session), {:deny, "t1", "not on my watch"})

      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000
      assert %{"output" => output, "error" => true} = tool_result(provider)
      assert output =~ "not on my watch"
    end

    test "denying without a reason gives the model the stock one", context do
      {session, provider, id} = parked(context)

      Dispatch.perform(acc(), host(session), {:deny, "t1", nil})

      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000
      assert %{"output" => output, "error" => true} = tool_result(provider)
      assert output =~ Deny.default_reason()
    end

    test "a call nobody is holding is said, not believed approved", context do
      {session, _provider, _id} = parked(context)

      acc = Dispatch.perform(acc(), host(session), {:approve, "nope"})

      assert said(acc) == [
               "nope is not waiting any more · it was answered elsewhere, or timed out"
             ]
    end
  end

  describe "a host's own command" do
    test "is performed through the dispatcher when the host passes its registry", context do
      {session, _provider} = start(context, [])
      conversation = Conversation.new(model: "test:model", commands: [Wave])
      acc = %{acc() | conversation: conversation}

      acc =
        Dispatch.perform(acc, host(session, commands: conversation.commands), {:wave, "alice"})

      assert said(acc) == ["waved at alice"]
    end

    test "is left alone by a dispatcher that was not given it", context do
      {session, _provider} = start(context, [])

      assert calls(Dispatch.perform(acc(), host(session), {:wave, "alice"})) == []
    end

    test "the dispatcher's default registry is the built-ins" do
      host = Dispatch.new(say: & &1, write: & &1, fold: & &1, run: & &1, react: & &1)

      assert host.commands == Builtin.all()
    end
  end

  describe "a person's own command" do
    test "runs in the session's working directory and is held for the next message",
         context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), host(session, cwd: context.tmp_dir), {:shell, "pwd"})

      assert [shown, "  · shared with your next message"] = said(acc)
      assert shown =~ "$ pwd\n"
      assert shown =~ Path.basename(context.tmp_dir)
      assert shown =~ "(exit 0)"
      assert [note] = acc.conversation.pending_context
      assert note =~ "You did not run it"
    end

    # The side door this closes: a session that withholds credentials from its
    # tools must withhold them from the person's `!` too.
    test "runs under the session environment's credential policy", context do
      {session, _provider} = start(context, [])
      name = "LMX_DISPATCH_TEST_TOKEN_#{System.unique_integer([:positive])}"
      System.put_env(name, "secret-value")
      on_exit(fn -> System.delete_env(name) end)

      environment = Local.new(credentials: {:scrub, []})

      acc =
        Dispatch.perform(
          acc(),
          host(session, cwd: context.tmp_dir, environment: environment),
          {:shell, "printenv #{name} || echo withheld"}
        )

      [shown | _rest] = said(acc)
      assert shown =~ "withheld"
      refute shown =~ "secret-value"
    end
  end

  describe "/diff" do
    defp git!(dir, args) do
      {_output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    end

    # Beside the session's own store, which writes into `tmp_dir`: its files
    # would otherwise be the repository's untracked ones.
    test "shows the working tree's changes and untracked files", context do
      dir = Path.join(context.tmp_dir, "repo")
      File.mkdir_p!(dir)
      git!(dir, ["init", "-q"])
      git!(dir, ["config", "user.email", "test@example.com"])
      git!(dir, ["config", "user.name", "Test"])
      File.write!(Path.join(dir, "a.txt"), "one\n")
      git!(dir, ["add", "a.txt"])
      git!(dir, ["commit", "-q", "-m", "first"])
      File.write!(Path.join(dir, "a.txt"), "two\n")
      File.write!(Path.join(dir, "new.txt"), "fresh\n")

      {session, _provider} = start(context, [])
      acc = Dispatch.perform(acc(), host(session, cwd: dir), :diff)

      [text] = said(acc)
      assert text =~ "changes since the last commit"
      assert text =~ "-one"
      assert text =~ "+two"
      assert text =~ "untracked:\n  new.txt"
    end

    # Outside the checkout this suite runs in: `tmp_dir` is inside it, and git
    # answers for the nearest repository above a directory.
    test "in a repository with no commit yet, and outside one", context do
      {session, _provider} = start(context, [])
      plain = Path.join(System.tmp_dir!(), "lmx-diff-#{System.unique_integer([:positive])}")
      File.mkdir_p!(plain)
      on_exit(fn -> File.rm_rf(plain) end)

      assert said(Dispatch.perform(acc(), host(session, cwd: plain), :diff)) == [
               "not a git repository · /diff shows a git working tree's changes"
             ]

      fresh = Path.join(context.tmp_dir, "fresh")
      File.mkdir_p!(fresh)
      git!(fresh, ["init", "-q"])

      assert said(Dispatch.perform(acc(), host(session, cwd: fresh), :diff)) == [
               "no changes in the working tree"
             ]
    end
  end

  describe "/export" do
    test "writes the conversation as Markdown and names the file", context do
      {session, _provider} = answered(context)
      exports = Path.join(context.tmp_dir, "exports")

      acc = Dispatch.perform(acc(), host(session, export_dir: exports), {:export, nil})

      assert ["exported this conversation to " <> path] = said(acc)
      assert Path.dirname(path) == exports
      markdown = File.read!(path)
      assert markdown =~ "## You\n\nhello"
      assert markdown =~ "## lmx\n\nhi back"
    end

    test "never replaces an existing file", context do
      {session, _provider} = answered(context)
      target = Path.join(context.tmp_dir, "notes.md")
      File.write!(target, "mine")

      acc = Dispatch.perform(acc(), host(session, cwd: context.tmp_dir), {:export, "notes.md"})

      assert [line] = said(acc)
      assert line =~ "already exists"
      assert File.read!(target) == "mine"
    end
  end

  describe "/doctor" do
    test "reports the session, permissions, checkpoints and the machine", context do
      {session, _provider} = start(context, [])

      [report] = said(Dispatch.perform(acc(), host(session), :doctor))

      assert report =~ "lmx doctor"
      assert report =~ "test:model"
      assert report =~ "permissions  off"
      assert report =~ "checkpoints  off"
      assert report =~ "platform"
    end
  end

  describe "/permissions" do
    alias Lemieux.Extensions.Permissions

    test "without a policy, says how to turn one on", context do
      {session, _provider} = start(context, [])

      [line] = said(Dispatch.perform(acc(), host(session), :permissions_status))
      assert line =~ "permissions are off"
    end

    test "switches the handle's mode and remembers rules", context do
      {session, _provider} = start(context, [])
      store = Path.join(context.tmp_dir, "permissions.json")
      {:ok, handle} = Permissions.new(mode: :ask, store: store)
      host = host(session, permissions: handle)

      assert ["permissions: accept edits, from the next tool call"] =
               said(Dispatch.perform(acc(), host, {:set_permission_mode, "accept_edits"}))

      assert Permissions.mode(handle) == :accept_edits

      Dispatch.perform(acc(), host, {:remember_permission, "Bash(mix test:*)"})
      assert "Bash(mix test:*)" in Permissions.remembered(handle)

      [status] = said(Dispatch.perform(acc(), host, :permissions_status))
      assert status =~ "[accept-edits]"
      assert status =~ "Bash(mix test:*)"

      Dispatch.perform(acc(), host, {:forget_permission, "Bash(mix test:*)"})
      refute "Bash(mix test:*)" in Permissions.remembered(handle)

      assert [refused] = said(Dispatch.perform(acc(), host, {:set_permission_mode, "sideways"}))
      assert refused =~ "usage: /permissions"
    end
  end

  describe "/undo" do
    test "without checkpoints, says there is nothing to put back", context do
      {session, _provider} = start(context, [])

      [line] = said(Dispatch.perform(acc(), host(session), {:undo, false}))
      assert line =~ "no checkpoints are recorded"
    end

    test "puts back what the agent changed and tells the model", context do
      {session, _provider} = start(context, [])
      id = Session.id(session)
      store = Path.join(context.tmp_dir, "checkpoints")
      work = Path.join(context.tmp_dir, "work")
      File.mkdir_p!(work)
      file = Path.join(work, "a.txt")
      File.write!(file, "before\n")

      checkpoint = %{cwd: work, session_id: id}
      {:ok, _turn} = Checkpoint.begin_turn(store, id)
      :ok = Checkpoint.capture(store, checkpoint, "a.txt")
      File.write!(file, "after\n")
      :ok = Checkpoint.record_after(store, checkpoint, "a.txt")

      acc = Dispatch.perform(acc(), host(session, checkpoints: store, cwd: work), {:undo, false})

      assert File.read!(file) == "before\n"
      assert [line] = said(acc)
      assert line =~ "undid turn 1"
      assert line =~ "restored a.txt"
      assert [note] = acc.conversation.pending_context
      assert note =~ "The person undid your file changes"

      again = Dispatch.perform(acc(), host(session, checkpoints: store), {:undo, false})
      assert [nothing] = said(again)
      assert nothing =~ "nothing to undo"
    end
  end

  describe "/verify and /delegate" do
    test "a session the verify extension shaped switches it and says how it stands", context do
      {:ok, harness} =
        Lemieux.Harness.assemble(Lemieux.Harness.new(), [
          {Lemieux.Extensions.Verify, command: "true"}
        ])

      {session, _provider} = start(context, [], harness: harness)

      assert ["verify off · the agent's edits are not checked automatically"] =
               said(Dispatch.perform(acc(), host(session), {:set_verify, false}))

      assert ["verify: off · nothing checked yet"] =
               said(Dispatch.perform(acc(), host(session), :verify_status))

      [report] = said(Dispatch.perform(acc(), host(session), :doctor))
      assert report =~ "extensions   Verify"
    end

    test "a session without the verify extension says so", context do
      {session, _provider} = start(context, [])

      [line] = said(Dispatch.perform(acc(), host(session), {:set_verify, true}))
      assert line =~ "verify is not part of this session"
    end

    defmodule Delegate do
      @moduledoc false
      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "delegate"
      @impl Lemieux.Tool
      def description, do: "Stands in for delegation."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object", "properties" => %{}}
      @impl Lemieux.Tool
      def run(_args, _context), do: {:ok, "done"}
    end

    test "/delegate switches the delegate tool", context do
      {session, _provider} = start(context, [], tools: [Echo, Delegate])

      off = Dispatch.perform(acc(), host(session), {:set_delegate, false})
      assert "delegation off" in said(off)
      assert {:react, :tools_changed} in calls(off)
      refute delegate_enabled?(session)

      on = Dispatch.perform(acc(), host(session), {:set_delegate, true})
      assert "delegation on" in said(on)
      assert delegate_enabled?(session)
    end

    defp delegate_enabled?(session),
      do: Enum.find(Session.tool_status(session), &(&1.name == "delegate")).enabled?

    test "a session with no delegate tool says so rather than enabling nothing", context do
      {session, _provider} = start(context, [], tools: [Echo])

      [line] = said(Dispatch.perform(acc(), host(session), {:set_delegate, true}))
      assert line =~ "no delegate tool"
    end
  end

  describe "/init and /memory" do
    test "/init sends the AGENTS.md brief as a turn", context do
      {session, _provider} = start(context, [Scripted.complete("I wrote it")])

      acc = Dispatch.perform(acc(), host(session, cwd: context.tmp_dir), :init)

      assert Enum.any?(said(acc), &(&1 =~ "asking the agent to write"))
      assert {:react, :turn_started} in calls(acc)
      assert acc.conversation.busy?
    end

    test "/memory appends to the personal file and tells this session now", context do
      {session, _provider} = start(context, [])
      personal = Path.join(context.tmp_dir, "home")

      acc =
        Dispatch.perform(
          acc(),
          host(session, personal_dir: personal),
          {:memory, :personal, "we use tabs"}
        )

      assert File.read!(Path.join(personal, "MEMORY.md")) =~ "we use tabs"
      assert [line] = said(acc)
      assert line =~ "remembered in"
      assert [note] = acc.conversation.pending_context
      assert note =~ "we use tabs"
    end
  end

  describe "MCP" do
    test "the listing is fetched as work, not on the host's own process", context do
      {session, _provider} = start(context, [])

      acc = Dispatch.perform(acc(), deferring(session), :mcp_status)
      assert {:mcp_listing, []} = deferred(acc)

      listed = Dispatch.perform(acc(), host(session), :mcp_status)
      assert {:react, {:mcp_statuses, []}} in calls(listed)
    end

    test "a session with no servers has no prompts", context do
      {session, _provider} = start(context, [])

      assert ["no connected MCP server offers prompts"] =
               said(Dispatch.perform(acc(), host(session), :mcp_prompts))
    end

    test "a prompt no server offers says so", context do
      {session, _provider} = start(context, [])

      [line] = said(Dispatch.perform(acc(), host(session), {:mcp_prompt, "mcp__x__y", ""}))
      assert line =~ "no connected MCP server offers this prompt"
    end
  end
end
