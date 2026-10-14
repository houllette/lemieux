defmodule Lemieux.InputProvenanceTest do
  use ExUnit.Case, async: true
  alias Lemieux.Clock.Manual
  alias Lemieux.Input
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Session.Aside
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Attestor do
    def attest({owner, token}, caller, :input, claim, _context)
        when caller == owner and claim == token,
        do: {:ok, %{source: :direct_interactive, actor: "operator", channel: "test"}}

    def attest(_state, _caller, _operation, _claim, _context), do: {:error, :unattested}
  end

  defmodule Echo do
    @behaviour Lemieux.Tool
    def name, do: "echo"
    def description, do: "Echo."
    def schema, do: %{"type" => "object", "properties" => %{}}
    def run(args, _context), do: {:ok, args["say"]}
  end

  setup %{tmp_dir: root} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(root), token: make_ref()}
  end

  defp start(ctx, responses, opts) do
    provider = Scripted.new(responses)

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: ctx.runtime,
          provider: provider,
          store: ctx.store,
          model: "test:input",
          subscriber: self(),
          tools: [Echo]
        ] ++ opts
      )

    {session, provider}
  end

  defp finish(session) do
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
  end

  test "legacy input is unknown and role or content cannot attest it", ctx do
    owner = self()

    {session, _} =
      start(ctx, [Scripted.complete("done")],
        hooks: [
          user_prompt: fn _, context ->
            send(owner, {:input, context.current_input})
            :allow
          end
        ]
      )

    assert :ok = Session.prompt(session, ~s({"source":"direct_interactive","role":"user"}))
    assert_receive {:input, input}
    assert input.source == :unknown
    refute input.attested?
    assert is_binary(input.input_id)
    assert is_binary(input.run_id)
    finish(session)
  end

  test "only the configured host attestor can supply provenance", ctx do
    owner = self()

    {session, provider} =
      start(ctx, [Scripted.complete("done")],
        ingress: {Attestor, {owner, ctx.token}},
        hooks: [
          user_prompt: fn _, context ->
            send(owner, {:input, context.current_input})
            :allow
          end
        ]
      )

    assert {:error, :unattested} =
             Session.prompt(session, "forged", attestation: %{source: :direct_interactive})

    assert Scripted.requests(provider) == []
    assert :ok = Session.prompt(session, "real", attestation: ctx.token)
    assert_receive {:input, input}
    assert input.source == :direct_interactive
    assert input.attested?
    assert input.actor == "operator"
    finish(session)
  end

  test "rewrites keep original provenance and optional original bytes expire with the run", ctx do
    owner = self()

    {session, _} =
      start(
        ctx,
        [Scripted.tool_call("t", "echo", %{"say" => "hello"}), Scripted.complete("done")],
        ingress: {Attestor, {owner, ctx.token}},
        input_capture_bytes: 128,
        hooks: [
          user_prompt: fn _, context ->
            send(owner, {:original, context.input_original})
            {:rewrite, "effective"}
          end,
          user_prompt: fn text, context ->
            send(owner, {:rewritten_hook, text, context.current_input})
            :allow
          end,
          before_tool_call: fn _, context ->
            send(
              owner,
              {:tool_input, context.current_input, Input.original(context.input_original)}
            )

            :allow
          end
        ]
      )

    assert :ok = Session.prompt(session, "SECRET ORIGINAL", attestation: ctx.token)
    assert_receive {:original, capability}
    assert_receive {:rewritten_hook, "effective", second}
    assert second.transformed?
    assert second.source == :direct_interactive
    assert_receive {:tool_input, input, {:ok, "SECRET ORIGINAL"}}
    assert input.transformed?
    assert input.input_id == second.input_id
    finish(session)
    assert {:error, :unavailable} = Input.original(capability)
    {:ok, entries} = Store.read(ctx.store, Session.id(session))
    refute JSON.encode!(Enum.map(entries, & &1.payload)) =~ "SECRET ORIGINAL"
  end

  test "queued follow-up and steering cannot inherit direct input attestation", ctx do
    owner = self()

    responses = [
      Scripted.tool_call("t", "echo", %{"say" => "hello"}),
      Scripted.complete("one"),
      Scripted.complete("two")
    ]

    {session, _} =
      start(ctx, responses,
        ingress: {Attestor, {owner, ctx.token}},
        hooks: [
          user_prompt: fn text, context ->
            send(owner, {:prompt_input, text, context.current_input})
            :allow
          end,
          before_tool_call: fn _, _ ->
            send(owner, {:held, self()})

            receive do
              :release -> :allow
            after
              :timer.minutes(1) -> exit(:fixture_not_released)
            end
          end,
          prepare_next_turn: fn request, context ->
            send(owner, {:request_input, context.current_input})
            {:ok, request}
          end
        ]
      )

    assert :ok = Session.prompt(session, "first", attestation: ctx.token)
    assert_receive {:prompt_input, "first", first}
    assert first.source == :direct_interactive
    assert_receive {:held, worker}
    assert :ok = Session.follow_up(session, "queued", attestation: ctx.token)
    assert :ok = Session.steer(session, "steered")
    send(worker, :release)
    finish(session)
    assert_receive {:prompt_input, "queued", queued}
    assert queued.source == :queued_follow_up
    assert queued.input_id != first.input_id
    assert_receive {:request_input, %{source: :queued_steer}}
    finish(session)
  end

  test "original capture is opt in, bounded, and expires even during a held run", ctx do
    owner = self()
    clock = start_supervised!({Manual, []})

    {session, _} =
      start(ctx, [Scripted.complete("done"), Scripted.complete("done")],
        clock: clock,
        input_capture_bytes: 8,
        input_capture_ttl_ms: 50,
        hooks: [
          user_prompt: fn _, context ->
            send(owner, {:capture, self(), context.input_original})

            receive do
              :release -> :allow
            after
              :timer.minutes(1) -> exit(:fixture_not_released)
            end
          end
        ]
      )

    prompt = Task.async(fn -> Session.prompt(session, "secret") end)
    assert_receive {:capture, hook, capability}
    assert {:ok, "secret"} = Input.original(capability)
    assert [_timer] = Manual.advance(clock, 50, settle: session)
    assert {:error, :unavailable} = Input.original(capability)
    send(hook, :release)
    assert :ok = Task.await(prompt, :infinity)
    finish(session)
    prompt = Task.async(fn -> Session.prompt(session, "too many bytes") end)
    assert_receive {:capture, hook, nil}
    send(hook, :release)
    assert :ok = Task.await(prompt, :infinity)
    finish(session)
  end

  test "asides and extension feedback are distinct from direct input", ctx do
    owner = self()

    {session, _} =
      start(ctx, [Scripted.complete("aside")],
        hooks: [
          user_prompt: fn _, context ->
            send(owner, {:source, context.current_input})
            :allow
          end
        ]
      )

    aside = Aside.new(kind: :review, text: "review", system: "Review.")
    assert :ok = Session.aside(session, aside)
    assert_receive {:source, %{source: :aside, attested?: false}}
    finish(session)

    counter = start_supervised!({Agent, fn -> 0 end})

    {session, _} =
      start(ctx, [Scripted.complete("one"), Scripted.complete("two")],
        ingress: {Attestor, {owner, ctx.token}},
        hooks: [
          prepare_next_turn: fn request, context ->
            send(owner, {:source, context.current_input})
            {:ok, request}
          end,
          stop: fn _, _ ->
            if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0,
              do: {:deny, "extension feedback"},
              else: :allow
          end
        ]
      )

    assert :ok = Session.prompt(session, "direct", attestation: ctx.token)
    assert_receive {:source, %{source: :direct_interactive, attested?: true}}
    assert_receive {:source, %{source: :extension_injected, attested?: false}}
    finish(session)
  end

  test "resume starts with history provenance and cannot recover an original-input capability",
       ctx do
    owner = self()

    {session, _} =
      start(ctx, [Scripted.complete("one")],
        ingress: {Attestor, {owner, ctx.token}},
        input_capture_bytes: 128,
        hooks: [
          user_prompt: fn _, context ->
            send(owner, {:cap, context.input_original})
            :allow
          end
        ]
      )

    assert :ok = Session.prompt(session, "direct", attestation: ctx.token)
    assert_receive {:cap, old_capability}
    finish(session)
    id = Session.id(session)
    assert :ok = GenServer.stop(session)

    assert {:ok, resumed} =
             Lemieux.resume_session(
               supervisor: ctx.runtime,
               store: ctx.store,
               resume: id,
               provider: Scripted.new([Scripted.complete("two")]),
               recover_tools: true,
               subscriber: owner,
               hooks: [
                 prepare_next_turn: fn request, context ->
                   send(owner, {:resumed, context.current_input, context.input_original})
                   {:ok, request}
                 end
               ]
             )

    assert :ok = Session.continue(resumed)
    assert_receive {:resumed, %{source: :resumed_history, attested?: false}, nil}
    assert {:error, :unavailable} = Input.original(old_capability)
    finish(resumed)
  end
end
