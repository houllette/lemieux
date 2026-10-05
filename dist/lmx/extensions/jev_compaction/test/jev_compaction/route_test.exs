defmodule LemieuxJevCompaction.RouteTest do
  use ExUnit.Case, async: true

  alias Lemieux.{Entry, Request, Session}
  alias Lemieux.Store.JSONL
  alias LemieuxJevCompaction, as: JevCompaction

  @moduletag :tmp_dir

  test "a compatible Ixway endpoint scores and projects a read over the real SDK wire", %{
    tmp_dir: dir
  } do
    body =
      JSON.encode!(%{
        "model" => "jev-local-1",
        "usage" => %{"input_tokens" => 30, "output_tokens" => 1},
        "answers" => %{"keep_1" => %{"type" => "noul", "noul" => 0.01}}
      })

    {endpoint, server} = endpoint(200, body)
    session = session(dir)
    {request, original} = request()

    opts = [
      route: :ixway,
      ixway_endpoint: endpoint,
      ixway_api_key: "private-gateway-test-key",
      model: "jev-local-1",
      preserve_recent_entries: 0,
      input_per_million: 0.04,
      output_per_million: 0.0
    ]

    assert {:ok, projected} = JevCompaction.prepare(request, %{session: session}, opts)
    assert List.last(projected.entries).payload["output"] != original
    assert List.last(projected.entries).payload["output"] =~ "rerun the tool"
    assert_receive {:system_one_wire, wire}, 2_000
    assert wire =~ "POST /v1/systemone HTTP/1.1"
    assert String.downcase(wire) =~ "authorization: bearer private-gateway-test-key"
    assert wire =~ ~s("model":"jev-local-1")
    refute wire =~ original

    assert {:ok, %{value: %{"last_outcome" => "applied"}}} =
             Session.document(session, "jev_compaction")

    assert_in_delta Session.budget(session).spent_usd, 30 * 0.04 / 1_000_000, 1.0e-12
    Task.await(server)
  end

  test "an Ixway rejection leaves the request intact and does not try hosted Jev", %{tmp_dir: dir} do
    {endpoint, server} = endpoint(401, ~s({"error":"unauthorized"}))
    session = session(dir)
    {request, _original} = request()

    opts = [
      route: :ixway,
      ixway_endpoint: endpoint,
      ixway_api_key: "private-gateway-test-key",
      api_key: "hosted-key-that-must-not-be-used",
      model: "jev-local-1",
      preserve_recent_entries: 0
    ]

    assert {:ok, ^request} = JevCompaction.prepare(request, %{session: session}, opts)
    assert_receive {:system_one_wire, wire}, 2_000
    assert wire =~ "POST /v1/systemone HTTP/1.1"

    assert {:ok, %{value: %{"last_outcome" => "failed", "attempts" => 1}}} =
             Session.document(session, "jev_compaction")

    assert Session.budget(session).spent_usd == nil
    Task.await(server)
  end

  test "a mismatched endpoint model cannot authorize elision", %{tmp_dir: dir} do
    body =
      JSON.encode!(%{
        "model" => "unexpected-model",
        "usage" => %{"input_tokens" => 30, "output_tokens" => 1},
        "answers" => %{"keep_1" => %{"type" => "noul", "noul" => 0.01}}
      })

    {endpoint, server} = endpoint(200, body)
    session = session(dir)
    {request, _original} = request()

    assert {:ok, ^request} =
             JevCompaction.prepare(request, %{session: session},
               route: :ixway,
               ixway_endpoint: endpoint,
               ixway_api_key: "private-gateway-test-key",
               model: "jev-local-1",
               preserve_recent_entries: 0
             )

    assert_receive {:system_one_wire, _wire}, 2_000

    assert {:ok, %{value: %{"last_outcome" => "failed"}}} =
             Session.document(session, "jev_compaction")

    Task.await(server)
  end

  test "a stalled endpoint times out without changing the request", %{tmp_dir: dir} do
    {endpoint, server} = endpoint(200, "", hold?: true)
    session = session(dir)
    {request, _original} = request()

    task =
      Task.async(fn ->
        JevCompaction.prepare(request, %{session: session},
          route: :ixway,
          ixway_endpoint: endpoint,
          ixway_api_key: "private-gateway-test-key",
          model: "jev-local-1",
          preserve_recent_entries: 0,
          timeout_ms: 50
        )
      end)

    assert_receive {:system_one_wire, _wire}, 2_000
    assert {:ok, ^request} = Task.await(task, 2_000)
    send(server.pid, :release)
    Task.await(server)

    assert {:ok, %{value: %{"last_outcome" => "failed", "attempts" => 1}}} =
             Session.document(session, "jev_compaction")
  end

  defp session(dir) do
    runtime = :"jev_route_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Lemieux.Providers.Scripted.new([]),
        store: JSONL.new(dir),
        model: "test:model",
        tools: [Lemieux.Tools.Read]
      )

    session
  end

  defp request do
    output = String.duplicate("old source line\n", 200)
    user = Entry.new(:user, %{"text" => "Find the new implementation"})

    assistant =
      Entry.new(:assistant, %{
        "content" => [],
        "tool_calls" => [
          %{"id" => "call-1", "name" => "read", "arguments" => %{"path" => "a.ex"}}
        ]
      })

    result =
      Entry.new(:tool_result, %{
        "call_id" => "call-1",
        "name" => "read",
        "arguments" => %{"path" => "a.ex"},
        "output" => output,
        "error" => false
      })

    {%Request{
       model: "test:model",
       entries: [user, assistant, result],
       tools: [Lemieux.Tools.Read]
     }, output}
  end

  defp endpoint(status, body, opts \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        wire = receive_request(socket, "")
        send(parent, {:system_one_wire, wire})

        if opts[:hold?] do
          receive do
            :release -> :ok
          end
        else
          reply =
            "HTTP/1.1 #{status} #{if status == 200, do: "OK", else: "Unauthorized"}\r\n" <>
              "content-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n" <>
              "connection: close\r\n\r\n" <> body

          :ok = :gen_tcp.send(socket, reply)
        end

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {"http://127.0.0.1:#{port}", server}
  end

  defp receive_request(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length) do
          bytes
        else
          receive_more(socket, bytes)
        end

      _ ->
        receive_more(socket, bytes)
    end
  end

  defp receive_more(socket, bytes) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
    receive_request(socket, bytes <> chunk)
  end
end
