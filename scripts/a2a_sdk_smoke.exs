# MIX_ENV=test LMX_CONFIG=none mise exec -- mix run scripts/a2a_sdk_smoke.exs /path/to/venv/bin/python
# Uses the real socket fixture and a scripted provider, with no API calls.
alias Lemieux.A2A.{Card, Handler, Server, SSE, Task}
alias Lemieux.Providers.Scripted

[python] = System.argv()
root = Path.join(System.tmp_dir!(), "lemieux-a2a-sdk-#{Lemieux.ID.generate()}")
File.mkdir_p!(root)
{:ok, runtime} = Lemieux.Supervisor.start_link(name: LemieuxA2ASDKSmoke)
provider = Scripted.new(List.duplicate(Scripted.complete("SDK interoperability answer"), 2))

{:ok, server} =
  Server.start_link(
    server_name: nil,
    supervisor: LemieuxA2ASDKSmoke,
    provider: provider,
    store: Lemieux.Store.JSONL.new(root),
    cwd: root,
    model: "test:model",
    interfaces: [{:jsonrpc, "https://example.org/rpc"}]
  )

opts = [server: server, principal: "python-sdk"]

url =
  LemieuxTest.HTTPAgent.start(fn
    "/.well-known/agent-card.json", _body ->
      {:ok, card} = Server.card(server: server)
      {200, Card.to_json(card)}

    _path, body ->
      method = JSON.decode!(body)["method"]

      if method == "SendStreamingMessage" do
        envelope = Handler.open_stream(body, opts)
        {:ok, task} = Task.from_json(envelope["result"]["task"])

        drain = fn drain, frames ->
          receive do
            {:a2a, id, event} when id == task.id ->
              frame = SSE.event(envelope["id"], task, event)

              case event do
                {:status, updated}
                when updated.state in [
                       :completed,
                       :failed,
                       :canceled,
                       :rejected,
                       :input_required,
                       :auth_required
                     ] ->
                  frames ++ [frame]

                _ ->
                  drain.(drain, frames ++ [frame])
              end
          after
            5_000 -> raise "SDK stream did not finish"
          end
        end

        {200, "text/event-stream", drain.(drain, [SSE.frame(envelope)]), 0}
      else
        {200, Handler.dispatch(body, opts)}
      end
  end)

try do
  {output, status} = System.cmd(python, ["scripts/a2a_sdk_smoke.py", url], stderr_to_stdout: true)
  IO.write(output)
  if status != 0, do: raise("Python SDK smoke failed")
  if length(Scripted.requests(provider)) != 2, do: raise("unexpected provider request count")
after
  GenServer.stop(server)
  Supervisor.stop(runtime)
  File.rm_rf!(root)
end
