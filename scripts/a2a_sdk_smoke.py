"""Optional provider-free interoperability check with official a2a-sdk==1.0.0.
Run through scripts/a2a_sdk_smoke.exs; no Python dependency enters the library.
"""
import asyncio
import sys

import httpx
from a2a import types
from a2a.client.transports.jsonrpc import JsonRpcTransport
from google.protobuf.json_format import ParseDict


async def main(url):
    async with httpx.AsyncClient(timeout=10) as http:
        card_json = (await http.get(url + "/.well-known/agent-card.json")).json()
        card = ParseDict(card_json, types.AgentCard(), ignore_unknown_fields=False)
        transport = JsonRpcTransport(http, card, url + "/rpc")
        request = ParseDict(
            {"message": {"messageId": "python-request", "role": "ROLE_USER",
                         "parts": [{"text": "Answer a source question"}]}},
            types.SendMessageRequest(), ignore_unknown_fields=False)
        response = await transport.send_message(request)
        assert response.WhichOneof("payload") == "task"
        assert response.task.status.state == types.TaskState.Value("TASK_STATE_COMPLETED")
        assert response.task.artifacts[0].parts[0].text == "SDK interoperability answer"
        retrieved = await transport.get_task(types.GetTaskRequest(id=response.task.id))
        assert retrieved.id == response.task.id
        request.message.message_id = "python-stream"
        frames = [frame async for frame in transport.send_message_streaming(request)]
        assert frames[0].WhichOneof("payload") == "task"
        assert any(frame.WhichOneof("payload") == "artifact_update" for frame in frames)
        assert frames[-1].status_update.status.state == types.TaskState.Value("TASK_STATE_COMPLETED")
        failure = await http.post(url + "/rpc", json={"jsonrpc": "2.0", "id": "missing",
                                  "method": "GetTask", "params": {"id": "missing"}})
        assert failure.json()["error"]["code"] == -32001
    print("Official Python SDK 1.0.0: card, SendMessage, GetTask, SSE, and error interoperability passed")


asyncio.run(main(sys.argv[1]))
