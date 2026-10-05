# Agent-to-agent communication

Lemieux can ask configured agents and export a bounded, read-only repository
service. A2A is opt-in at both ends. Loading the library or launching `lmx`
starts no A2A server, discovers no remote HTTP peers and spends no peer quota.

The HTTP contract is pinned to [A2A 1.0.0](https://a2a-protocol.org/v1.0.0/specification/).
JSON-RPC and SSE are implemented; Erlang distribution is a custom binding for
trusted runtimes. HTTP listeners, TLS, authentication, tenant routing and budgets
shared across instances belong to the embedding host, so the library takes no
web or database dependency for any of it.

## Ask a configured peer from lmx

Add this to your personal configuration (`~/.lmx/config.json`, or `--config`):

```json
{
  "version": 1,
  "a2a_peers": {
    "backend": {
      "url": "https://backend.example.org/rpc",
      "bearer_env": "BACKEND_A2A_TOKEN"
    }
  }
}
```

Set the credential environment variable separately. `bearer_env` is optional
for endpoints that require no credential. Endpoints cannot contain credentials,
query strings or fragments. Only configured names are available to the model;
it cannot invent an endpoint or authentication option.

`/a2a` lists the configured names without a network call. `/a2a ask backend
where is request authentication enforced?` submits a normal prompt that uses
`ask_agent`. The same tool works in headless sessions. Its operations are
`ask`, `card`, `task`, `cancel` and `list`; `task_id` continues an interrupted
task, and `answers` supplies a questionnaire response. Results retain task IDs,
status, source artifacts and the full structured question. Peer content is
labelled untrusted. Ordinary tool policy, output limits and transcript rendering
still apply. `/tools disable ask_agent` disables it for the current session;
`"disabled_extensions": ["a2a"]` disables the shipped recipe.

Each prepared extension has an eight-call allowance and a sixty-second call
deadline. Failures consume the allowance. A host can set `:max_calls` and
`:timeout` on `Lemieux.Extensions.A2A`. Re-preparing a host creates a new
allowance: this is a session guard, not a tenant-wide quota. A timed-out ask
may still be running remotely; use `list` and `task` to find it before retrying.
Disabling the tool does not cancel work already accepted by a peer.

Peer requests disclose their message to the peer and can spend its provider
quota. Local task usage metadata does not include that remote spend. Returned
remote usage is evidence, not an invoice, a subscription saving or local billed
cost. Credentials stay in host executor state and never enter descriptor or
extension provenance. Peer configuration is supplied again on resume rather
than restored as authority from a transcript.

An embedder can use the extension without a CLI:

```elixir
{:ok, harness} = Lemieux.Harness.assemble(%Lemieux.Harness{}, [
  {Lemieux.Extensions.A2A,
   peers: %{"backend" => %{"url" => "https://backend.example.org/rpc"}},
   max_calls: 4, timeout: 30_000}
])
```

Hosts that use slash commands also pass
`commands: [Lemieux.Conversation.Command.A2A]` to this extension. The CLI does
that itself; the protocol layer depends on no terminal host.

## Direct client operations

```elixir
opts = [auth: {:bearer, token}, timeout: 30_000]
{:ok, card} = Lemieux.A2A.card("https://backend.example.org/rpc", opts)
{:ok, task} = Lemieux.A2A.ask("https://backend.example.org/rpc", "Where is auth checked?", opts)
answer = Lemieux.A2A.Task.text(task)
{:ok, current} = Lemieux.A2A.task("https://backend.example.org/rpc", task.id, opts)
```

`SendMessage` can return a task or a direct Message map. Check task status:
`input_required` is a pause, while `completed`, `failed`, `canceled` and
`rejected` are final. Unknown task IDs are errors. Terminal tasks never accept
continuations. Legacy in-memory text artifacts remain readable through
`Lemieux.A2A.Task.text/1`; HTTP uses canonical `artifactId` and `parts` objects.

```elixir
{:ok, done} = Lemieux.A2A.ask(endpoint, %{
  "taskId" => paused.id,
  "parts" => [%{"data" => %{"answers" => [
    %{"text" => "production"}, %{"text" => "v2"}
  ]}}]
}, opts)
```

Questionnaire answers follow the question order. Choice questions use
`selected`, rankings use `ranked`, numeric questions use `number`, and text
questions use `text`. Incomplete or invalid answers leave the task waiting.
Legacy single-question tasks can still accept a text continuation.

All client operations forward authentication and timeouts. Options also include
`:history_length`, `:return_immediately`, `:max_response_bytes` (default 2 MB),
and `:max_frame_bytes` (default 256 KB). Redirects and automatic retries are
both disabled. HTTP deadlines bound the whole request as well as inactivity.

`Lemieux.A2A.Transport.HTTP.discover/2` fetches
`/.well-known/agent-card.json` and selects a JSONRPC interface advertising 1.0,
skipping unsupported bindings and versions. The caller decides whether to
trust the returned URL and whether to apply its credential there. `ask/3`
uses the supplied endpoint directly and does not silently switch origins.

`ask(endpoint, message, stream: self())` uses SendStreamingMessage. Updates
arrive as `{:a2a, task_id, {:status, task}}` and `{:a2a, task_id, {:delta, text}}`;
the call returns on a terminal or interrupted status. Direct streaming Message
replies use `{:message, message}`. Premature EOF is an error. Reconnect with
`Lemieux.A2A.subscribe(endpoint, task_id, stream: self())`, or retrieve the
current task first. Reconnection never resends a message automatically.

## Export a repository service

Mount the runtime and server explicitly. Give each server a separate private
journal directory and keep both journal and transcript stores outside the
exported checkout:

```elixir
children = [
  {Lemieux.Supervisor, name: MyHost.Runtime},
  {Lemieux.A2A.Server,
   supervisor: MyHost.Runtime,
   provider: provider,
   store: Lemieux.Store.JSONL.new("/private/a2a/transcripts"),
   model: model,
   cwd: "/work/backend",
   name: "Backend source guide",
   interfaces: [{:jsonrpc, "https://backend.example.org/rpc"}],
   task_directory: "/private/a2a/tasks",
   read_paths: ["lib/**", "docs/**", "mix.exs"],
   max_requests: 8,
   max_total_requests: 128}
]
```

The server checks its task-session options once, when it is mounted. With a
provider or store that is not a `{module, state}` pair, or no model, it
refuses to start: `start_link/1` returns
`{:error, {:invalid_session_options, key}}`, where `key` is `:provider`,
`:store` or `:model`, rather than failing every remote ask later. The value
itself is never put in the reason, because providers and stores carry
credentials.

`Lemieux.A2A.Policy` resolves the host harness before choosing read-only tools.
It constructs a fresh session with its own task system prompt. Operator entries,
operator system prompts, host tools, hooks, MCP connections and restoration
metadata are not inherited. AskUser is included only when explicitly equipped.
Custom tools declared read-only are trusted host code; the declaration does not
sandbox arbitrary Elixir code.

The environment rejects writes, shell execution and paths outside the checkout,
including escaping symlinks. Common credential/configuration paths, `.git`,
transcripts and the configured private stores are excluded. `:read_paths` and
`:deny_paths` further restrict exported data. File-name exclusions cannot prove
that every allowed source file is free of secrets; a host should select its
exported files deliberately. Custom tools that bypass the environment need
host-enforced data isolation.

Defaults are four concurrent tasks, 128 retained tasks, one-hour terminal
retention, a three-minute execution deadline (including time awaiting answers),
64 KB input, 256 KB output, sixteen subscribers per task, eight provider
requests per task, twelve turns, and a server-wide 128-request allowance.
All limits are configurable except the subscriber ceiling. Admission reserves
the full request allowance and never refunds it, including after failures. This
conservative ledger survives restart when a journal is configured. Session
`:max_cost_usd` retains its refusal to spend when pricing is unknown. Budgets,
source revision/dirty state and reported usage appear in task metadata; absent
cost remains unknown. Source metadata is a working-tree observation at task
creation, not a frozen checkout. It is read through
`Lemieux.Checkpoint.Git.revision/1` and `status/2`, which run nothing the
repository configures: an exported checkout may be one that agents' commands
also write, and a plain `git status` on the host would run a
`core.fsmonitor` or filter planted in its `.git/config`.

Cancel replies contain the canceled task immediately. Finished, failed and
canceled tasks release sessions, monitors, timers and subscriptions. Session
death becomes a failed task. A lifecycle guard cleans up sessions if the server
itself dies. Terminal results expire; active tasks end by their deadline before
retention can remove them.

Use `:server_name` to select registration, or nil for an anonymous server, and
`:server` on direct client/server calls to select an instance. When mounting
multiple children, give each an explicit `Supervisor.child_spec/2` ID.

## Attach the host's authenticated HTTP endpoint

Authenticate the incoming request in the host, derive a stable opaque caller
identity, and pass it to `Lemieux.A2A.Handler`:

```elixir
response = Lemieux.A2A.Handler.dispatch(body,
  server: server,
  principal: authenticated_identity,
  version: a2a_version_header
)
# Write JSON.encode!(response) as application/json.
```

A missing principal is rejected. Clients cannot provide the principal in their
message. Send, get, cancel, subscribe and list all enforce owner scope; an
unknown task and another owner's task return the same TaskNotFound response.
The host enforces HTTP body limits, tenant routing, TLS, authentication and
quotas shared across processes or machines. Public cards can declare
`:security_schemes` and `:security_requirements`; these describe authentication
and do not implement it. No HTTP listener is started here.

For SSE, call `Handler.open_stream/2` with the authenticated options. Write its
successful initial envelope through `SSE.frame/1`, then receive task mailbox
updates and write `SSE.event(request_id, initial_task, event)`. Close on an
interrupted or terminal status. On disconnect call `Handler.close_stream/2`;
this removes the subscription while the bounded task remains retrievable. An
initial error is an ordinary JSON-RPC error, not an SSE success. Serve the
public card separately with `Server.card/1` and `Card.to_json/1`. Public cards
omit filesystem paths, model routes and credentials.

`ListTasks` supports caller-scoped pagination, context/status/timestamp filters,
history limits and opt-in artifacts. Push notifications return the registered
PushNotificationNotSupported error. Extended cards return
ExtendedAgentCardNotConfigured. The card advertises streaming and no push
notifications. HTTP+JSON, gRPC and OAuth negotiation are not claimed; hosts can
add bindings through `Lemieux.A2A.Transport` without changing the agent loop.

## Recovery and ownership of durable workflows

Without `:task_directory`, the projection and admission ledger are in memory.
With it, the server atomically replaces a private task journal at transitions
and usage reports. Completed results and ownership survive restart. Lost
active or interrupted executions become failed with an explicit restart reason;
provider calls are never silently replayed. Corrupt or unwritable journals fail
closed. This is process-crash recovery, not an fsync/power-loss guarantee. One
server owns one directory; concurrent writers are unsupported.

The durable session transcript remains separate. An orchestrating host, an
application that embeds Lemieux and runs durable workflows, owns workflow
graphs, human inboxes, exactly-once effects, long-lived resumption, database
task stores, distributed quotas and scheduling. The task projection provides
the protocol boundary such a host can build on without moving a web server or
database into the core library.

For trusted BEAM peers, `Lemieux.A2A.ask(:"backend@host", "question")` uses
distribution. Erlang distribution uses TCP and normally epmd. A shared cookie
authorizes arbitrary VM RPC; read-only A2A policy does not sandbox a cookie
holder. `nearby/0` lists connected peers that actually serve A2A; it creates no
atoms from unrelated epmd advertisements.

## Validation

The local server regressions exercise capability filtering, private context,
structured continuation, cancellation, session death, deadlines, ownership,
retention, admission, private stores and restart recovery. Independently authored
1.0 fixtures and real TCP tests check field names, authentication, correlation,
response limits and fragmented SSE. The distributed suite uses real BEAM peers.

An optional check uses the official Python SDK with a scripted provider:

```sh
python3 -m venv /tmp/a2a-sdk-check
/tmp/a2a-sdk-check/bin/pip install a2a-sdk==1.0.0
MIX_ENV=test LMX_CONFIG=none mise exec -- mix run scripts/a2a_sdk_smoke.exs /tmp/a2a-sdk-check/bin/python
```

This checks card parsing, SendMessage, GetTask, streaming and numeric errors
through the SDK's actual JSON-RPC transport. It makes no provider calls and adds
no dependency to the library. It does not establish compatibility with every
SDK or deployed peer, nor does it establish a production host's authentication
or provider behavior. Contributors changing the A2A code run `mix precommit`
and `mix test.distributed` before opening a pull request.
