defmodule Lemieux.SessionDedupTest do
  @moduledoc """
  A session writes each large value its requests repeat once, refers to it
  afterwards, and every reader still sees the whole payloads.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  @system String.duplicate("Be careful, and say what you checked. ", 100)

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_dedup_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(tmp_dir), dir: tmp_dir}
  end

  defp start(context, prompts, opts \\ []) do
    provider = Scripted.new(Enum.map(prompts, &Scripted.complete("answer to #{&1}")))

    {:ok, session} =
      Lemieux.start_session(
        Keyword.merge(
          [
            supervisor: context.runtime,
            provider: provider,
            store: context.store,
            model: "test:model",
            system: @system,
            subscriber: self()
          ],
          opts
        )
      )

    for prompt <- prompts, do: {:ok, _result} = Session.await(session, prompt, timeout: 10_000)
    session
  end

  defp written(context, session) do
    context.dir
    |> Path.join(Session.info(session).id <> ".jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  test "later requests refer to the system prompt they repeat; readers get it whole", context do
    session = start(context, ["one", "two", "three"])

    lines = written(context, session)
    requests = Enum.filter(lines, &(&1["type"] == "request"))

    # Written whole once in the file — by the session entry that records the
    # configuration, which comes first — and referred to by every request.
    assert Enum.count(lines, &(&1["payload"]["system"] == @system)) == 1
    assert length(requests) == 3
    assert Enum.all?(requests, &match?(%{"$sha256" => _digest}, &1["payload"]["system"]))
    assert Enum.all?(requests, &(&1["v"] == Lemieux.Entry.compacted_version()))

    {:ok, read} = Store.read(context.store, Session.info(session).id)
    requests = Enum.filter(read, &(&1.type == :request))

    assert length(requests) == 3
    assert Enum.all?(requests, &(&1.payload["system"] == @system))
    assert Enum.all?(requests, &(Lemieux.RequestSnapshot.verify(&1.payload) == :ok))

    # What the live session holds is what a reader gets back.
    assert Enum.map(Session.snapshot(session).entries, & &1.payload) ==
             Enum.map(read, & &1.payload)
  end

  test "a resumed session keeps referring to what the file already holds", context do
    session = start(context, ["one"])
    id = Session.info(session).id
    :ok = GenServer.stop(session)

    {:ok, resumed} =
      Lemieux.resume_session(
        supervisor: context.runtime,
        provider: Scripted.new([Scripted.complete("again")]),
        store: context.store,
        resume: id,
        subscriber: self()
      )

    {:ok, _result} = Session.await(resumed, "again", timeout: 10_000)

    lines = written(context, resumed)
    requests = Enum.filter(lines, &(&1["type"] == "request"))

    # Still written whole only once, though a second process wrote the rest.
    assert Enum.count(lines, &(&1["payload"]["system"] == @system)) == 1
    assert length(requests) == 2
    assert Enum.all?(requests, &match?(%{"$sha256" => _digest}, &1["payload"]["system"]))
  end

  defp tool_loop(context, opts \\ []) do
    for name <- ~w(a b c), do: File.write!(Path.join(context.dir, "#{name}.txt"), name)

    provider =
      Scripted.new([
        Scripted.tool_call("c1", "read", %{"path" => "a.txt"}),
        Scripted.tool_call("c2", "read", %{"path" => "b.txt"}),
        Scripted.tool_call("c3", "read", %{"path" => "c.txt"}),
        Scripted.complete("read them all")
      ])

    {:ok, session} =
      Lemieux.start_session(
        Keyword.merge(
          [
            supervisor: context.runtime,
            provider: provider,
            store: context.store,
            model: "test:model",
            system: @system,
            subscriber: self(),
            cwd: context.dir,
            tools: [Lemieux.Tools.Read]
          ],
          opts
        )
      )

    {:ok, _result} = Session.await(session, "read the files", timeout: 10_000)
    Session.snapshot(session).entries
  end

  test "a run writes its harness snapshot once, however many requests it makes", context do
    entries = tool_loop(context)

    requests = Enum.filter(entries, &(&1.type == :request))
    assert length(requests) == 4
    assert [snapshot] = Enum.filter(entries, &(&1.type == :harness_snapshot))
    assert Enum.all?(requests, &(&1.payload["harness_snapshot_id"] == snapshot.payload["id"]))
  end

  test "digests evidence keeps what identifies a request, not the prompt or schemas",
       context do
    entries = tool_loop(context, evidence: :digests)

    [request | _rest] = Enum.filter(entries, &(&1.type == :request))
    assert request.payload["evidence"] == "digests"
    assert request.payload["system"] == nil
    assert request.payload["system_bytes"] == byte_size(@system)
    assert byte_size(request.payload["system_sha256"]) == 64
    assert request.payload["tools"] == [%{"name" => "read"}]
    assert Lemieux.RequestSnapshot.verify(request.payload) == :ok
    assert Enum.any?(entries, &(&1.type == :run_evidence))
  end

  test "evidence off writes no harness snapshots or run evidence", context do
    entries = tool_loop(context, evidence: :off)

    assert Enum.count(entries, &(&1.type == :request)) == 4
    refute Enum.any?(entries, &(&1.type in [:harness_snapshot, :run_evidence]))
  end

  # The reduction the audit record was costing, measured the way the review
  # measured a real session: twenty requests under one system prompt and one
  # catalog.
  test "twenty requests write their prompt and catalog once", context do
    tools = [Lemieux.Tools.Read, Lemieux.Tools.Write, Lemieux.Tools.Edit, Lemieux.Tools.Bash]
    prompts = Enum.map(1..20, &"question #{&1}")

    compact = start(context, prompts, tools: tools)
    full = start(context, prompts, tools: tools, transcript_dedup: false)

    compact_bytes = transcript_bytes(context, compact)
    full_bytes = transcript_bytes(context, full)

    assert compact_bytes < div(full_bytes, 3)
  end

  defp transcript_bytes(context, session),
    do:
      context.dir
      |> Path.join(Session.info(session).id <> ".jsonl")
      |> File.stat!()
      |> Map.get(:size)

  test "a host can turn references off", context do
    session = start(context, ["one", "two"], transcript_dedup: false)

    requests = context |> written(session) |> Enum.filter(&(&1["type"] == "request"))

    assert Enum.all?(requests, &(&1["payload"]["system"] == @system))
  end
end
