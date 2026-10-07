defmodule Lemieux.Session.AsideTest do
  @moduledoc """
  The session's one-off request on a host's behalf, proven without the loop
  knowing what the request is for.

  Every kind here is invented by the test — `:judge`, `:review` — so nothing
  passes because the session recognises a name. What reflection needs of the
  same facility is proven from the outside, in `Lemieux.ReflectionTest`.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Session.Aside
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"aside_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp session(context, script, opts \\ []) do
    provider = Scripted.new(script)

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          system: "Original task instructions",
          tools: [Lemieux.Tools.Write],
          subscriber: self(),
          cwd: context.tmp_dir
        ] ++ opts
      )

    {session, provider, Session.id(session)}
  end

  defp judge(fields \\ []) do
    Aside.new(
      Keyword.merge([kind: :judge, text: "/judge", system: "Judge the work so far."], fields)
    )
  end

  test "an aside is a tool-free request with its own system text and kind, and the next turn is untouched",
       context do
    {session, provider, id} =
      session(context, [
        Scripted.complete("Built"),
        Scripted.complete("Verdict"),
        Scripted.complete("Continued")
      ])

    :ok = Session.prompt(session, "Build it")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert :ok = Session.aside(session, judge())
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    :ok = Session.prompt(session, "Continue")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    [initial, aside, continued] = Scripted.requests(provider)
    assert aside.system == "Judge the work so far."
    assert aside.tools == []
    assert aside.output_schema == nil
    assert Enum.map(aside.entries, & &1.payload["text"]) == ["/judge"]
    assert continued.system == initial.system
    assert continued.tools == initial.tools

    entries = Session.snapshot(session).entries
    assert Enum.any?(entries, &(&1.type == :user and &1.payload == %{"text" => "/judge"}))
    assert Enum.any?(entries, &(&1.type == :request and &1.payload["kind"] == "judge"))
    assert Session.snapshot(session).status == :idle
  end

  test "an aside may send the transcript, or entries of its own, ahead of its prompt", context do
    {session, provider, id} =
      session(context, [
        Scripted.complete("Built"),
        Scripted.complete("Over the transcript"),
        Scripted.complete("Over borrowed entries")
      ])

    :ok = Session.prompt(session, "Build it")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert :ok = Session.aside(session, judge(entries: :transcript))
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    borrowed = Entry.new(:user, %{"text" => "borrowed"})
    assert :ok = Session.aside(session, judge(kind: :review, entries: [borrowed]))
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    [_initial, transcript, own] = Scripted.requests(provider)

    texts = fn request ->
      for %{type: :user} = entry <- request.entries, do: entry.payload["text"]
    end

    assert texts.(transcript) == ["Build it", "/judge"]
    assert Enum.any?(transcript.entries, &(&1.type == :assistant))
    assert texts.(own) == ["borrowed", "/judge"]
    refute Enum.any?(own.entries, &(&1.type == :assistant))
  end

  test "an aside carries its output schema through to the provider", context do
    schema = %{"type" => "object", "properties" => %{"score" => %{"type" => "number"}}}
    {session, provider, id} = session(context, [Scripted.complete(~s({"score": 1}))])

    assert :ok = Session.aside(session, judge(output_schema: schema))
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert [%{output_schema: ^schema, tools: []}] = Scripted.requests(provider)
  end

  test "an aside's text is a prompt to the model, not a line to expand references from",
       context do
    File.write!(Path.join(context.tmp_dir, "notes.txt"), "a file a prompt would attach")
    text = "consider @notes.txt"

    {session, provider, id} =
      session(context, [Scripted.complete("noted"), Scripted.complete("attached")])

    assert :ok = Session.aside(session, judge(text: text))
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    :ok = Session.prompt(session, text)
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    [aside, prompt] = Scripted.requests(provider)
    [aside_entry] = aside.entries
    refute Map.has_key?(aside_entry.payload, "attachments")
    prompt_entry = List.last(prompt.entries)
    assert [%{"path" => "notes.txt"}] = prompt_entry.payload["attachments"]
  end

  test "an aside is refused while the session is busy, and a busy aside refuses a prompt",
       context do
    parent = self()

    {session, provider, id} =
      session(context, [
        fn _request ->
          send(parent, :aside_started)
          Scripted.delayed(10_000, Scripted.complete("late"))
        end,
        Scripted.complete("normal")
      ])

    assert :ok = Session.aside(session, judge())
    assert_receive :aside_started
    assert {:error, :busy} = Session.aside(session, judge())
    assert {:error, :busy} = Session.prompt(session, "now")
    assert :ok = Session.cancel(session)
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}

    :ok = Session.prompt(session, "continue")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert List.last(Scripted.requests(provider)).system == "Original task instructions"
    assert List.last(Scripted.requests(provider)).tools == [Lemieux.Tools.Write]
  end

  test "a model that calls a tool during an aside is denied, and the aside ends in error",
       context do
    {session, _provider, id} =
      session(context, [
        Scripted.tool_call("write", "write", %{"path" => "unwanted.txt", "content" => "oops"})
      ])

    assert :ok = Session.aside(session, judge())
    assert_receive {:lemieux, ^id, {:finished, :error}}
    refute File.exists?(Path.join(context.tmp_dir, "unwanted.txt"))

    assert Enum.any?(
             Session.snapshot(session).entries,
             &(&1.type == :tool_result and &1.payload["outcome"] == "denied")
           )
  end

  test "a steer typed during an aside waits for the next prompt rather than extending it",
       context do
    parent = self()

    {session, provider, id} =
      session(context, [
        fn _request ->
          send(parent, {:aside_started, self()})

          receive do
            :release -> Scripted.complete("verdict")
          after
            5_000 -> Scripted.complete("verdict")
          end
        end,
        Scripted.complete("next")
      ])

    assert :ok = Session.aside(session, judge())
    assert_receive {:aside_started, turn}
    assert :ok = Session.steer(session, "also this")
    send(turn, :release)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 1

    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [_aside, next] = Scripted.requests(provider)
    texts = for %{type: :user} = entry <- next.entries, do: entry.payload["text"]
    assert "also this" in texts
  end

  test "an aside cannot bypass a spent request allowance", context do
    {session, provider, id} = session(context, [Scripted.complete("done")], max_requests: 1)
    :ok = Session.prompt(session, "task")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert :ok = Session.aside(session, judge())
    assert_receive {:lemieux, ^id, {:finished, {:budget, %{kind: :requests}}}}
    assert length(Scripted.requests(provider)) == 1
  end

  test "an aside a prompt hook denies leaves the session ready for the next one", context do
    hooks = [
      user_prompt: fn
        "/judge", _context -> {:deny, "no judging here"}
        _text, _context -> :allow
      end
    ]

    {session, provider, id} = session(context, [Scripted.complete("fine")], hooks: hooks)

    assert {:error, {:hook_denied, "no judging here"}} = Session.aside(session, judge())
    assert Session.snapshot(session).status == :idle

    :ok = Session.prompt(session, "carry on")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert [%{system: "Original task instructions", tools: [Lemieux.Tools.Write]}] =
             Scripted.requests(provider)
  end

  test "a stop hook is told when the stop ends an aside, and by which kind", context do
    parent = self()
    hooks = [stop: fn _reason, hook_context -> send(parent, {:aside, hook_context.aside}) end]

    {session, _provider, id} =
      session(context, [Scripted.complete("Built"), Scripted.complete("Verdict")], hooks: hooks)

    :ok = Session.prompt(session, "build")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert_receive {:aside, nil}

    :ok = Session.aside(session, judge())
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert_receive {:aside, :judge}
  end

  test "an aside needs a kind, a text and a system" do
    assert_raise ArgumentError, fn -> Aside.new(text: "/judge", system: "Judge.") end
    assert_raise ArgumentError, fn -> Aside.new(kind: :judge, system: "Judge.") end
    assert_raise ArgumentError, fn -> Aside.new(kind: :judge, text: "/judge") end

    assert_raise ArgumentError, fn ->
      Aside.new(kind: "judge", text: "/judge", system: "Judge.")
    end
  end
end
