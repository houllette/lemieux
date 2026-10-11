defmodule Lemieux.Session.DocumentRequestTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir
  @usage %{"input_tokens" => 10, "output_tokens" => 3, "cost_usd" => 0.002}

  defp start(dir, script, opts \\ []) do
    runtime = :"document_request_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    provider = Scripted.new(script, estimated_cost_usd: 0.002)

    {:ok, session} =
      Lemieux.start_session(
        Keyword.merge(
          [
            supervisor: runtime,
            provider: provider,
            model: "test:model",
            store: JSONL.new(dir),
            tools: []
          ],
          opts
        )
      )

    {session, provider, runtime}
  end

  defp request,
    do:
      Request.new("test:model",
        system: "A label",
        tools: [Lemieux.Tools.Bash],
        params: [max_tokens: 128]
      )

  defp build({:ok, text}), do: %{"text" => text}
  defp build({:error, _reason}), do: %{"failed" => true}

  test "refuses stale revisions and cost ceilings before contacting the provider", %{tmp_dir: dir} do
    {session, provider, _runtime} = start(dir, [], max_cost_usd: 0.001)

    assert {:error, :conflict} =
             Session.generate_document(session, "label", 1, request(), &build/1)

    assert {:error, %{cap: 0.001, estimate: 0.002}} =
             Session.generate_document(session, "label", 0, request(), &build/1)

    assert {:error, :invalid_options} =
             Session.generate_document(session, "label", 0, request(), &build/1, timeout_ms: 0)

    assert Scripted.requests(provider) == []
  end

  test "assembled text wins, tools are removed, and one request is durably counted", %{
    tmp_dir: dir
  } do
    {session, provider, _runtime} =
      start(dir, [
        [
          {:text_delta, "draft"},
          {:message,
           %{
             "content" => [
               %{"type" => "thinking", "text" => "private"},
               %{"type" => "text", "text" => "Final label"}
             ]
           }},
          {:usage, @usage},
          {:done, :stop}
        ]
      ])

    assert {:ok, %{revision: 1, value: %{"text" => "Final label"}}} =
             Session.generate_document(session, "label", 0, request(), &build/1)

    assert [%{tools: []}] = Scripted.requests(provider)
    assert %{requests: 1, spent_usd: 0.002} = Session.budget(session)
    refute Enum.any?(Session.snapshot(session).entries, &(&1.type in [:user, :assistant]))
  end

  test "cancellation kills the request and keeps unknown spend after resume", %{tmp_dir: dir} do
    parent = self()

    {session, _provider, runtime} =
      start(dir, [
        fn _request ->
          send(parent, {:started, self()})
          Scripted.delayed(60_000, Scripted.complete("late"))
        end
      ])

    task =
      Task.async(fn -> Session.generate_document(session, "label", 0, request(), &build/1) end)

    assert_receive {:started, provider_pid}
    monitor = Process.monitor(provider_pid)
    assert {:error, :busy} = Session.prompt(session, "next")
    assert :ok = Session.cancel(session)
    assert {:ok, %{value: %{"failed" => true}}} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^provider_pid, _reason}
    assert Session.budget(session).spent_usd == nil
    id = Session.id(session)
    GenServer.stop(session)

    {:ok, resumed} =
      Lemieux.resume_session(
        supervisor: runtime,
        provider: Scripted.new([]),
        store: JSONL.new(dir),
        resume: id
      )

    assert %{requests: 1, spent_usd: nil} = Session.budget(resumed)
  end

  test "timeout releases the session and cannot publish a late answer", %{tmp_dir: dir} do
    parent = self()

    {session, _provider, _runtime} =
      start(dir, [
        fn _request ->
          send(parent, :started)
          Scripted.delayed(60_000, Scripted.complete("late"))
        end
      ])

    task =
      Task.async(fn -> Session.generate_document(session, "label", 0, request(), &build/1) end)

    assert_receive :started
    %{document_request: %{ref: ref}} = :sys.get_state(session)
    send(session, {:document_timeout, ref})
    assert {:ok, %{value: %{"failed" => true}}} = Task.await(task)
    assert Session.info(session).status == :idle
    send(session, {:document_event, ref, {:text_delta, "late"}})
    assert {:ok, %{value: %{"failed" => true}}} = Session.document(session, "label")
  end

  test "a competing writer wins and usage is counted once", %{tmp_dir: dir} do
    parent = self()

    {session, _provider, _runtime} =
      start(dir, [
        fn _request ->
          send(parent, {:started, self()})

          receive do
            :release -> Scripted.complete("generated", usage: @usage)
          end
        end
      ])

    task =
      Task.async(fn -> Session.generate_document(session, "label", 0, request(), &build/1) end)

    assert_receive {:started, worker}

    assert {:ok, %{revision: 1}} =
             Session.put_document(session, "label", 0, %{"text" => "manual"})

    send(worker, :release)
    assert {:error, :conflict} = Task.await(task)
    assert {:ok, %{value: %{"text" => "manual"}}} = Session.document(session, "label")
    assert Session.budget(session).spent_usd == 0.002
  end
end
