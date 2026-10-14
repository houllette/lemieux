defmodule Lemieux.ScopedApprovalTest do
  use ExUnit.Case, async: true
  alias Lemieux.Clock.Manual
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  defmodule Attestor do
    def attest({owner, token}, caller, :approval, claim, _context)
        when caller == owner and claim == token,
        do: {:ok, %{source: :host_rpc, actor: "operator", channel: "authenticated"}}

    def attest(_, _, _, _, _), do: {:error, :unattested}
  end

  defmodule Echo do
    @behaviour Lemieux.Tool
    def name, do: "echo"
    def description, do: "Echo."

    def schema,
      do: %{
        "type" => "object",
        "properties" => %{"say" => %{"type" => "string"}},
        "required" => ["say"]
      }

    def run(args, _context), do: {:ok, "echo: #{args["say"]}"}
  end

  defmodule Wrapper do
    @behaviour Lemieux.Tool.Configured
    defstruct [:child]
    def name(_tool), do: "echo"
    def description(_tool), do: "Outer wrapper."
    def schema(_tool), do: Echo.schema()

    def run(tool, args, context) do
      result =
        Lemieux.Tools.run(
          [tool.child],
          context.hooks,
          %{id: "inner", name: "echo", arguments: args},
          context
        )

      if result.error?, do: {:error, result.output}, else: {:ok, result.output}
    end
  end

  setup %{tmp_dir: root} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(root), token: make_ref()}
  end

  defp start(ctx, opts \\ []) do
    {pending_id, opts} = Keyword.pop(opts, :pending_call_id, "t")

    provider =
      Scripted.new([
        Scripted.tool_call("t", "echo", %{"say" => "SECRET ARGUMENT"}),
        Scripted.complete("done")
      ])

    {:ok, session} =
      Lemieux.start_session(
        Keyword.merge(
          [
            supervisor: ctx.runtime,
            provider: provider,
            store: ctx.store,
            model: "test:approval",
            subscriber: self(),
            tools: [Echo],
            ingress: {Attestor, {self(), ctx.token}},
            approval_mode: :scoped,
            hooks: [before_tool_call: fn _, _ -> :pending end]
          ],
          opts
        )
      )

    assert :ok = Session.prompt(session, "run")
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:tool_approval, %{id: ^pending_id}}}
    assert {:ok, request} = Session.approval_request(session, pending_id)
    {session, provider, request}
  end

  defp finish(session, provider) do
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [_first, last] = Scripted.requests(provider)
    Enum.find(Enum.reverse(last.entries), &(&1.type == :tool_result)).payload
  end

  test "a live matching allow-once requires host attestation and is single use", ctx do
    {session, provider, request} = start(ctx)
    assert {:error, :unscoped_resolution} = Session.resolve_tool(session, "t", :allow)

    assert {:error, :unattested} =
             Session.resolve_approval(session, request, :allow_once,
               attestation: %{source: :direct_interactive, actor: "operator"}
             )

    assert length(Scripted.requests(provider)) == 1
    assert :ok = Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)
    result = finish(session, provider)
    assert result["output"] == "echo: SECRET ARGUMENT"
    refute result["error"]

    assert {:error, :unknown_call} =
             Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)

    {:ok, entries} = Store.read(ctx.store, Session.id(session))
    audit = Enum.filter(entries, &(&1.type == :approval)) |> Enum.map(& &1.payload)
    refute JSON.encode!(audit) =~ "SECRET ARGUMENT"
    refute JSON.encode!(audit) =~ request.nonce
    assert List.last(audit)["resolver"]["source"] == "host_rpc"
  end

  test "mismatched scope cannot consume a live request", ctx do
    {session, provider, request} = start(ctx)

    for changed <- [
          %{request | scope: "wrong"},
          %{request | nonce: "wrong"},
          %{request | run_id: "wrong"}
        ] do
      assert {:error, :stale_approval} =
               Session.resolve_approval(session, changed, :allow_once, attestation: ctx.token)
    end

    assert {:ok, ^request} = Session.approval_request(session, "t")
    assert :ok = Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)
    refute finish(session, provider)["error"]
  end

  test "later hook argument rewrites invalidate the approved action", ctx do
    {session, provider, request} =
      start(ctx,
        hooks: [
          before_tool_call: fn _, _ -> :pending end,
          before_tool_call: fn _, _ -> {:rewrite, %{"say" => "changed"}} end
        ]
      )

    assert :ok = Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)
    result = finish(session, provider)
    assert result["error"]
    assert result["output"] =~ "fresh approval"
  end

  test "host execution-context changes invalidate an allow before invocation", ctx do
    epoch = start_supervised!({Agent, fn -> 0 end})

    {session, provider, request} =
      start(ctx, approval_context: fn _ -> Agent.get(epoch, & &1) end)

    Agent.update(epoch, &(&1 + 1))
    assert :ok = Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)
    result = finish(session, provider)
    assert result["error"]
    assert result["output"] =~ "fresh approval"
  end

  test "a rewrite is a proposal and requires a new nonce and decision", ctx do
    {session, provider, request} = start(ctx)

    assert :ok =
             Session.resolve_approval(session, request, {:request_rewrite, %{"say" => "new"}},
               attestation: ctx.token
             )

    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:tool_approval, %{arguments: %{"say" => "new"}}}}
    assert {:ok, next} = Session.approval_request(session, "t")
    assert next.nonce != request.nonce
    assert next.scope != request.scope
    send(session, {:approval_timeout, "t", request.id})
    send(session, {:park_timeout, "t"})
    assert {:ok, ^next} = Session.approval_request(session, "t")
    assert length(Scripted.requests(provider)) == 1

    assert {:error, :stale_approval} =
             Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)

    assert :ok = Session.resolve_approval(session, next, :allow_once, attestation: ctx.token)
    assert finish(session, provider)["output"] == "echo: new"
  end

  test "cancellation and expiry never resurrect a grant", ctx do
    clock = start_supervised!({Manual, []})
    {session, provider, request} = start(ctx, clock: clock, approval_ttl_ms: 100)
    assert [_timer] = Manual.advance(clock, 100, settle: session)
    assert finish(session, provider)["error"]

    assert {:error, :unknown_call} =
             Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)

    {session, _provider, request} = start(ctx)
    assert :ok = Session.cancel(session)

    assert {:error, :unknown_call} =
             Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)
  end

  test "loaded implementation changes invalidate approval before execution", ctx do
    module = Module.concat(__MODULE__, "Dynamic#{System.unique_integer([:positive])}")
    compile_echo(module, "old implementation")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    {session, provider, request} = start(ctx, tools: [module])
    :code.purge(module)
    :code.delete(module)
    compile_echo(module, "new implementation")
    assert :ok = Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)
    result = finish(session, provider)
    assert result["error"]
    assert result["output"] =~ "fresh approval"
    refute result["output"] =~ "new implementation"
  end

  defp compile_echo(module, output) do
    Code.compile_string("""
    defmodule #{inspect(module)} do
      @behaviour Lemieux.Tool
      def name, do: "echo"
      def description, do: "Dynamic echo."
      def schema, do: %{"type" => "object", "properties" => %{}}
      def run(_args, _context), do: {:ok, #{inspect(output)}}
    end
    """)
  end

  test "resume cannot restore a request even with the same session and call identifiers", ctx do
    {session, _provider, old} = start(ctx)
    assert :ok = Session.cancel(session)
    assert :ok = GenServer.stop(session)

    provider =
      Scripted.new([
        Scripted.tool_call("t", "echo", %{"say" => "new"}),
        Scripted.complete("done")
      ])

    assert {:ok, resumed} =
             Lemieux.resume_session(
               supervisor: ctx.runtime,
               store: ctx.store,
               resume: old.session_id,
               recover_tools: true,
               provider: provider,
               subscriber: self(),
               tools: [Echo],
               ingress: {Attestor, {self(), ctx.token}},
               approval_mode: :scoped,
               hooks: [before_tool_call: fn _, _ -> :pending end]
             )

    assert :ok = Session.continue(resumed)
    id = Session.id(resumed)
    assert_receive {:lemieux, ^id, {:tool_approval, %{id: "t"}}}
    assert {:ok, current} = Session.approval_request(resumed, "t")
    assert current.nonce != old.nonce
    assert current.scope != old.scope

    assert {:error, :stale_approval} =
             Session.resolve_approval(resumed, old, :allow_once, attestation: ctx.token)

    assert :ok = Session.resolve_approval(resumed, current, :allow_once, attestation: ctx.token)
    assert finish(resumed, provider)["output"] == "echo: new"
  end

  test "rewrites are validated before a replacement challenge is advertised", ctx do
    {session, provider, request} = start(ctx)

    assert :ok =
             Session.resolve_approval(session, request, {:request_rewrite, %{"say" => 3}},
               attestation: ctx.token
             )

    result = finish(session, provider)
    assert result["error"]
    assert result["output"] =~ "tool schema"
    assert {:error, :unknown_call} = Session.approval_request(session, "t")
  end

  test "nested calls bind the inner executor rather than inheriting an outer approval", ctx do
    module = Module.concat(__MODULE__, "Nested#{System.unique_integer([:positive])}")
    compile_echo(module, "old child")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    {session, provider, request} =
      start(ctx,
        tools: [%Wrapper{child: module}],
        pending_call_id: "inner",
        hooks: [
          before_tool_call: fn _, context ->
            if get_in(context.tool_descriptor, ["interface", "description"]) == "Outer wrapper.",
              do: :allow,
              else: :pending
          end
        ]
      )

    :code.purge(module)
    :code.delete(module)
    compile_echo(module, "new child")
    assert :ok = Session.resolve_approval(session, request, :allow_once, attestation: ctx.token)
    result = finish(session, provider)
    assert result["error"]
    assert result["output"] =~ "fresh approval"
    refute result["output"] =~ "new child"
  end
end
