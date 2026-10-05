defmodule Lemieux.SessionRobustnessTest do
  @moduledoc """
  The ways a long, real session used to end early, one describe block each.

  A transcript written by two processes at once; a question to a host that
  copied the whole session to answer it; an approval that timed out because
  its tool's clock kept running; a poll mistaken for a loop; a record that
  failed to build and took the session down after the work was done; MCP
  servers that made the session deaf while they started; a window nobody
  knew; a summary that failed once and switched compaction off for good.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Session.Aside
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Supervisor, as: Sup

  @moduletag :tmp_dir

  @fixture Path.expand("../fixtures/mcp_server.py", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_robust_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start_session(context, script, opts \\ []) do
    provider = Keyword.get_lazy(opts, :provider, fn -> Scripted.new(script) end)

    {:ok, session} =
      [
        supervisor: context.runtime,
        provider: provider,
        store: context.store,
        model: "test:model",
        subscriber: self(),
        tools: []
      ]
      |> Keyword.merge(Keyword.delete(opts, :provider))
      |> Lemieux.start_session()

    {session, provider}
  end

  defp answer(text, input_tokens) do
    [
      {:text_delta, text},
      {:usage, %{"input_tokens" => input_tokens, "output_tokens" => 0}},
      {:done, :stop}
    ]
  end

  defp say(session, text) do
    :ok = Session.prompt(session, text)
    assert_receive {:lemieux, _id, {:finished, _reason}}, 5_000
  end

  # Reports a job that never finishes, the way `bash` reports a background
  # task: the same words each time, with a status that says it is running.
  defmodule Poll do
    @moduledoc false
    @behaviour Lemieux.Tool

    alias Lemieux.Tool.Result

    @impl true
    def name, do: "poll"
    @impl true
    def description, do: "Reports on a job."
    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def run(_args, _context) do
      {:ok, Result.new("job 7: still running", structured_content: %{"status" => "running"})}
    end
  end

  # The same words with no status: a model asking a finished question again.
  defmodule Same do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl true
    def name, do: "poll"
    @impl true
    def description, do: "Reports on a job."
    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def run(_args, _context), do: {:ok, "job 7: done"}
  end

  # A scripted provider whose model offers reasoning efforts, which the
  # shipped scripted one does not.
  defmodule Thinking do
    @moduledoc false
    @behaviour Lemieux.Provider

    alias Lemieux.Providers.Scripted

    def new(script), do: {__MODULE__, Scripted.new(script)}

    @impl true
    def run({Scripted, agent}, request, emit), do: Scripted.run(agent, request, emit)
    @impl true
    def context_window(_scripted, _model), do: nil
    @impl true
    def available_models(_scripted, _opts), do: []
    @impl true
    def validate_model(_scripted, _model, _tools), do: :ok
    @impl true
    def reasoning_efforts(_scripted, _model), do: ["default", "low", "high"]
    @impl true
    def estimate_cost(_scripted, _request), do: nil

    def requests({__MODULE__, scripted}), do: Scripted.requests(scripted)
  end

  describe "one writer per transcript" do
    test "a second session on the same id is refused while the first holds it", context do
      other = :"lemieux_robust_other_#{System.unique_integer([:positive])}"
      start_supervised!(Supervisor.child_spec({Lemieux.Supervisor, name: other}, id: other))

      {session, _provider} = start_session(context, [Scripted.complete("hi")])
      id = Session.id(session)

      assert {:error, {:session_locked, holder}} =
               Lemieux.start_session(
                 supervisor: other,
                 provider: Scripted.new([]),
                 store: context.store,
                 model: "test:model",
                 id: id
               )

      # Atom keys, the shape every host wording the refusal reads.
      assert holder.os_pid == System.pid()
      assert is_binary(holder.host)
      assert String.ends_with?(holder.path, id <> ".lock")

      :ok = DynamicSupervisor.terminate_child(Sup.session_supervisor(context.runtime), session)

      assert {:ok, _resumed} =
               Lemieux.resume_session(
                 supervisor: other,
                 provider: Scripted.new([]),
                 store: context.store,
                 resume: id
               )
    end

    test "a host that opts out of the lock is not refused", context do
      other = :"lemieux_robust_other_#{System.unique_integer([:positive])}"
      start_supervised!(Supervisor.child_spec({Lemieux.Supervisor, name: other}, id: other))

      {session, _provider} = start_session(context, [])

      assert {:ok, _second} =
               Lemieux.start_session(
                 supervisor: other,
                 provider: Scripted.new([]),
                 store: context.store,
                 model: "test:model",
                 id: Session.id(session),
                 transcript_lock: false
               )
    end
  end

  describe "info/1" do
    test "answers what a screen asks, without copying the transcript", context do
      {session, _provider} = start_session(context, [Scripted.complete("hi")], max_requests: 20)
      say(session, "hello")

      info = Session.info(session)

      refute Map.has_key?(info, :entries)
      assert info.requests == 1
      assert info.max_requests == 20
      assert info.status == :idle
      assert info.ready? == true
      assert info.mcp == []
      assert info.context_window_known? == false
    end
  end

  describe "prompting and waiting" do
    test "await returns the answer, the prompt's usage and what it wrote", context do
      script = [
        [
          {:text_delta, "hel"},
          {:text_delta, "lo"},
          {:usage, %{"input_tokens" => 10, "output_tokens" => 2}},
          {:done, :stop}
        ]
      ]

      {session, _provider} = start_session(context, script, subscriber: nil)
      owner = self()

      assert {:ok, result} =
               Session.await(session, "say hello", on_event: &send(owner, {:seen, &1}))

      assert result.text == "hello"
      assert result.stop_reason == :stop
      assert result.error == nil
      assert result.usage["input_tokens"] == 10
      assert result.session_id == Session.id(session)
      assert :assistant in Enum.map(result.entries, & &1.type)
      assert %Entry{type: :user} = hd(result.entries)
      assert_received {:seen, {:finished, :stop}}
      # Only the collector was subscribed: none of the session's own events
      # arrive in the caller's mailbox.
      refute_received {:lemieux, _id, _event}
    end

    # Nothing else would ever send the `:finished` the wait is for, so a
    # session that dies mid-prompt must end the wait rather than hang it.
    test "await returns session_down when the session dies during the wait", context do
      script = [Scripted.delayed(5_000, Scripted.complete("too late"))]
      {session, _provider} = start_session(context, script, subscriber: nil)

      kill_once_prompted = fn
        {:entry, %Entry{type: :user}} -> Process.exit(session, :kill)
        _event -> :ok
      end

      assert {:error, {:session_down, :killed}} =
               Session.await(session, "wait for me", on_event: kill_once_prompted)
    end

    test "await on a session that is already gone says so", context do
      {session, _provider} = start_session(context, [], subscriber: nil)
      ref = Process.monitor(session)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}

      assert {:error, {:session_down, _reason}} = Session.await(session, "anyone?")
    end

    test "Lemieux.run starts a session, answers, and stops it", context do
      assert {:ok, result} =
               Lemieux.run("go",
                 supervisor: context.runtime,
                 provider: Scripted.new([Scripted.complete("one-shot")]),
                 store: context.store,
                 model: "test:model"
               )

      assert result.text == "one-shot"
      LemieuxTest.Sync.unregistered(Sup.registry(context.runtime), result.session_id)
      assert Lemieux.session(context.runtime, result.session_id) == :error

      assert {:ok, entries} = Store.read(context.store, result.session_id)
      assert Enum.any?(entries, &(&1.type == :assistant))
    end
  end

  describe "a call waiting for somebody" do
    setup %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "note.txt"), "hello")
      :ok
    end

    defp parked_session(context, opts) do
      start_session(
        context,
        [Scripted.tool_call("c1", "read", %{"path" => "note.txt"}), Scripted.complete("done")],
        Keyword.merge(
          [
            tools: [Lemieux.Tools.Read],
            cwd: context.tmp_dir,
            hooks: [before_tool_call: fn _call, _context -> :pending end]
          ],
          opts
        )
      )
    end

    # The tool's whole deadline passes while the approval is pending. It used to
    # keep running, and the person's "yes" approved a call that had timed out.
    #
    # Driven by a manual clock: time passes only when the test says, so a slow
    # machine cannot make the deadline fire before the call has parked.
    test "does not lose its tool's deadline while it waits", context do
      clock = start_supervised!(Manual)
      {session, _provider} = parked_session(context, tool_timeout_ms: 100, clock: clock)
      id = Session.id(session)

      :ok = Session.prompt(session, "read it")
      assert_receive {:lemieux, ^id, {:tool_approval, _call}}

      # The tool's whole deadline two and a half times over; the approval's
      # own five-minute timeout is nowhere near.
      Manual.advance(clock, 250, settle: session)
      :ok = Session.resolve_tool(session, "c1", :allow)
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      {:ok, entries} = Store.read(context.store, id)
      assert [result] = Enum.filter(entries, &(&1.type == :tool_result))
      assert result.payload["error"] == false
      assert result.payload["output"] =~ "hello"
    end

    test "can wait without a clock when the host says somebody will answer", context do
      {session, _provider} = parked_session(context, approval_timeout: :infinity)
      id = Session.id(session)

      :ok = Session.prompt(session, "read it")
      assert_receive {:lemieux, ^id, {:tool_approval, _call}}
      assert [%{call_id: "c1"}] = Session.snapshot(session).pending

      :ok = Session.resolve_tool(session, "c1", :allow)
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert Session.resolve_tool(session, "c1", :allow) == {:error, :unknown_call}
    end
  end

  describe "a poll is not a loop" do
    defp polls(count), do: for(n <- 1..count, do: Scripted.tool_call("p#{n}", "poll", %{}))

    test "a result still in progress is waited on, not counted as a repeat", context do
      {session, provider} =
        start_session(context, polls(5) ++ [Scripted.complete("finished")], tools: [Poll])

      say(session, "wait for the job")

      assert length(Scripted.requests(provider)) == 6
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :error))
    end

    test "the same finished answer three times is still no progress", context do
      {session, provider} =
        start_session(context, polls(5) ++ [Scripted.complete("finished")], tools: [Same])

      id = Session.id(session)
      :ok = Session.prompt(session, "wait for the job")

      assert_receive {:lemieux, ^id, {:finished, :no_progress}}, 5_000
      assert length(Scripted.requests(provider)) == 3
    end
  end

  describe "run evidence" do
    test "a run whose record cannot be built still finishes, and the session goes on",
         context do
      {session, _provider} =
        start_session(context, [Scripted.complete("hi"), Scripted.complete("again")],
          harness_context: %{"sandbox_completeness" => "not a completeness"}
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "go")

      assert_receive {:lemieux, ^id, {:run_evidence_failed, %{run_id: run_id}}}
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      say(session, "again")

      {:ok, entries} = Store.read(context.store, id)

      assert [%Entry{payload: %{"degraded" => true, "run_id" => ^run_id}} | _rest] =
               Enum.filter(entries, &(&1.type == :run_evidence))
    end
  end

  describe "MCP servers starting" do
    defp server,
      do: %{"name" => "fixture", "command" => "python3", "args" => [@fixture, "modern"]}

    # Stops each server's launch until the test lets it go, so "still
    # connecting" is a state the test holds rather than a race it hopes for.
    defp gated_launcher(owner) do
      fn command, args, _env, cwd ->
        send(owner, {:launching, self()})

        receive do
          :go -> :ok
        end

        port =
          Port.open({:spawn_executable, System.find_executable(command)}, [
            :binary,
            :exit_status,
            :hide,
            args: args,
            cd: cwd
          ])

        {:ok, port}
      end
    end

    defp start_gated(context, script, opts \\ []) do
      start_session(
        context,
        script,
        Keyword.merge(
          [
            mcp_servers: [server()],
            mcp_stdio_launcher: gated_launcher(self()),
            cwd: context.tmp_dir
          ],
          opts
        )
      )
    end

    defp tool_names(request), do: Enum.map(request.tools, &Lemieux.Tool.name/1)

    test "connect in the background, and the session answers meanwhile", context do
      {session, _provider} = start_gated(context, [])
      assert_receive {:launching, launcher}, 5_000

      info = Session.info(session, 1_000)
      assert info.ready? == false
      assert [%{name: "fixture", status: :connecting, tool_count: 0}] = info.mcp

      send(launcher, :go)

      assert_receive {:lemieux, _id,
                      {:ready, %{mcp: [%{name: "fixture", status: :connected, tool_count: 4}]}}},
                     10_000

      assert Session.info(session).ready? == true
    end

    test "a first prompt waits for a server still connecting", context do
      {session, provider} = start_gated(context, [Scripted.complete("hi")])
      assert_receive {:launching, launcher}, 5_000

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _id, {:waiting_for_mcp, %{servers: ["fixture"]}}}
      assert Session.info(session).status == :busy

      send(launcher, :go)
      assert_receive {:lemieux, _id, {:finished, :stop}}, 10_000

      assert [request] = Scripted.requests(provider)
      assert "fixture__echo" in tool_names(request)
    end

    test "once the grace is spent the request goes without it", context do
      {session, provider} = start_gated(context, [Scripted.complete("hi")], mcp_grace_ms: 0)
      assert_receive {:launching, launcher}, 5_000

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _id, {:finished, :stop}}, 5_000

      assert [request] = Scripted.requests(provider)
      refute Enum.any?(tool_names(request), &String.starts_with?(&1, "fixture__"))

      send(launcher, :go)
      assert_receive {:lemieux, _id, {:mcp_server, %{status: :connected}}}, 10_000
    end

    test "questions about the catalog wait for the answer rather than guessing", context do
      {session, _provider} = start_gated(context, [])
      assert_receive {:launching, launcher}, 5_000

      status = Task.async(fn -> Session.mcp_status(session, 10_000) end)
      refute Task.yield(status, 100)

      send(launcher, :go)
      assert [%{name: "fixture", tool_count: 4}] = Task.await(status, 10_000)
    end
  end

  describe "a window nobody knew" do
    test "is learned from a refusal that states it", context do
      {session, _provider} =
        start_session(context, [Scripted.stated_context_limit(50_000)], provider_retry: false)

      say(session, "a prompt too large")

      assert %{context_window_known?: true, context: %{window: 50_000}} = Session.info(session)
    end
  end

  describe "requests a host composes" do
    # A request that ended on an assistant message would be read as a reply to
    # continue. An aside's own question is the last thing it sends.
    test "an aside over the transcript ends on its own question", context do
      {session, provider} =
        start_session(context, [Scripted.complete("the answer"), Scripted.complete("reviewed")])

      say(session, "do the work")

      aside =
        Aside.new(
          kind: :review,
          text: "Review it",
          system: "Review.",
          entries: :transcript
        )

      :ok = Session.aside(session, aside)
      assert_receive {:lemieux, _id, {:finished, :stop}}, 5_000

      assert %Entry{type: :user, payload: %{"text" => "Review it"}} =
               provider
               |> Scripted.requests()
               |> List.last()
               |> Map.fetch!(:entries)
               |> List.last()
    end
  end

  describe "summarising" do
    defp four_roomy_turns do
      [answer("ok", 1_000), answer("ok", 1_000), answer("ok", 1_000), answer("ok", 9_000)]
    end

    test "asks for low effort, room to write, and ends on a request for the summary", context do
      script =
        four_roomy_turns() ++
          [[{:text_delta, "They said hello."}, {:done, :stop}], answer("after", 1_000)]

      provider = Thinking.new(script)

      {session, _provider} =
        start_session(context, [],
          provider: provider,
          context_window: 10_000,
          compact_at: 0.8,
          reasoning_effort: "high"
        )

      for n <- 1..5, do: say(session, "prompt #{n}")

      summarising = Enum.at(Thinking.requests(provider), 4)
      assert summarising.params[:reasoning_effort] == "low"
      assert summarising.params[:max_tokens] == 8_192
      assert %Entry{type: :user, meta: %{"synthetic" => true}} = List.last(summarising.entries)
      # The turns keep the effort the session was given.
      assert Enum.at(Thinking.requests(provider), 5).params[:reasoning_effort] == "high"
    end

    test "a summary that fails transiently is tried once more", context do
      script =
        four_roomy_turns() ++
          [
            Scripted.http_error(503, headers: %{"retry-after" => "0"}),
            [{:text_delta, "They said hello."}, {:done, :stop}],
            answer("after", 1_000)
          ]

      {session, provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..5, do: say(session, "prompt #{n}")

      assert length(Scripted.requests(provider)) == 7
      entries = Session.snapshot(session).entries
      assert Enum.any?(entries, &(&1.type == :compaction))
      assert Enum.any?(entries, &(&1.type == :error and &1.payload["retrying"] == true))
    end

    # One failure used to turn threshold compaction off for the rest of the
    # session. Now it waits out a backoff counted in requests, then tries again.
    test "after a failure the threshold waits a little, not forever", context do
      script =
        four_roomy_turns() ++
          [
            [{:error, "the summariser is down"}],
            answer("carrying on", 9_500),
            answer("still going", 9_500),
            [{:text_delta, "They said hello."}, {:done, :stop}],
            answer("after", 1_000)
          ]

      {session, provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      id = Session.id(session)
      for n <- 1..6, do: say(session, "prompt #{n}")
      assert length(Scripted.requests(provider)) == 7

      :ok = Session.prompt(session, "prompt 7")
      assert_receive {:lemieux, ^id, {:compacted, _compacted}}, 5_000
      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000
      assert length(Scripted.requests(provider)) == 9
    end
  end
end
