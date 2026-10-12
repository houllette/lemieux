# Editor connections with ACP

Configure an ACP editor to launch `lmx` with `args: ["acp"]`. Existing CLI
options, credentials, permission rules, sandbox selection and budgets apply.
The adapter starts native Lemieux sessions; the editor does not get a second
execution policy. To use a checkout, compile first, then launch
`mix lmx acp`. Mix compilation output is not protocol traffic.

The transport is newline-delimited JSON-RPC 2.0 on stdin/stdout. stdout is
reserved for packets. Each input frame is limited to 1 MiB; a connection owns at
most 16 open sessions. EOF cancels work, closes sessions and releases their
transcript locks. A partial frame at EOF is discarded.

## Supported contract

The implementation follows the upstream
[ACP schemas](https://github.com/agentclientprotocol/agent-client-protocol/tree/main/schema).
Initialization negotiates version 1 or 2. Other versions receive the latest supported version (2)
and must disconnect if they cannot speak it. Credentials are supplied by the
host configuration; no interactive authentication methods are advertised.

| Operation | Behavior |
| --- | --- |
| `session/new` | Requires an existing absolute `cwd`; connects explicitly supplied stdio MCP servers. |
| `session/list` | Reads durable user conversations, 50 per page; optional `cwd` filter and opaque cursor. |
| `session/load` (v1) | Loads a closed session and replays retained conversation before replying. |
| `session/resume` | Reopens a closed session under current host authority, with matching `cwd`. Version 2 replays only for `replayFrom: {type: "start"}`. |
| `session/prompt` | Accepts text and resource links; unsupported content is rejected before a model request. Resource links become named references for the model, without an automatic external fetch. |
| `session/update` | Streams text/thinking and tool activity. Version 2 also sends message replacement and foreground state updates. |
| `session/request_permission` | Parks an actual tool call. Only a correlated `allow_once` response authorizes it. Rejection, malformed responses and cancellation grant nothing. |
| `session/cancel` / `session/close` | Cancels work; close also releases the transcript lock. Late permission replies are discarded. |

Version 1 holds the prompt response until completion and returns `stopReason`.
Version 2 replies with the persisted user `messageId` when accepted, echoes
that message, and reports completion with `state_update: idle`. Clients must
use their negotiated version's lifecycle. There is no automatic retry of a
prompt that failed, and prompts received while busy are rejected.

The adapter does not advertise images, audio, embedded resource contents,
HTTP/SSE MCP transport, additional roots, client filesystem or terminal
delegation, session deletion, or interactive authentication. File and shell
tools run through the host environment. Unsupported replay cursors are
rejected. This is protocol qualification with local fixtures; individual
editor releases still need interactive testing before claiming compatibility.

## Optional Lemieux extensions

Initialization advertises `_meta.lemieux.question` and `steer`. To receive
questions, the client sets `capabilities._meta.lemieux.question: true`
(version 1: `clientCapabilities`). The agent sends a JSON-RPC request named
`_lemieux/question` containing `sessionId` and the native questionnaire. The
client returns `{answer: "text"}` or the structured questionnaire answer.
Unsupported clients receive no question request; the tool records that no
answer was provided, rather than waiting forever or inventing consent.

`_lemieux/steer` takes `{sessionId, text}` and uses the public steering seam.
These are namespaced extensions, not standard ACP methods. Use
`session/cancel` to interrupt a turn.

`_lemieux/fork` takes `{sessionId, atSeq?}` on an idle session and returns the
new `sessionId`, using the transcript's safe-boundary checks. The fork retains
history and restrictions but mounts current host authority. No tool is replayed.
`_lemieux/configure` takes `{sessionId, model}` or `{sessionId,
reasoningEffort}` (one setting per request). Public session validation rejects
busy or unsupported changes; permissions and budgets cannot be widened through
this endpoint. Initialization advertises both extensions under `_meta.lemieux`.
