# Editor connections with ACP

Configure an ACP editor to launch `lmx` with `args: ["acp"]`. Existing CLI
options, credentials, permission rules, sandbox selection and budgets apply.
The adapter starts native Lemieux sessions; the editor does not get a second
execution policy. To use a checkout, compile first, then launch
`mix lmx acp`. Mix compilation output is not protocol traffic.

## Use Lemieux in Zed

Install `lmx`, then open Zed's Agent Settings → External Agents → Add Agent →
Add Custom Agent. Merge this entry into your user settings, replacing the
command with your installed launcher's absolute path:

```json
{
  "agent_servers": {
    "Lemieux": {
      "type": "custom",
      "command": "/absolute/path/to/lmx",
      "args": ["acp"],
      "env": {}
    }
  }
}
```

Select **Lemieux** from the Agent Panel's new-thread menu. Zed starts the
process and supplies the project's working directory through ACP. An absolute
command path avoids depending on the environment a GUI launch inherits.

Run `lmx acp setup` in a terminal to choose a model and, when needed, save a
provider key. Setup exits after saving and makes no model request. It uses the
same private configuration writer as the terminal UI. Editors advertising
terminal authentication can offer this setup inside their own terminal.
Authentication arguments retain the ACP launch flags, including `--config`.
After setup, a new session reloads the configuration.

Credentials and defaults belong to [Lemieux's configuration](configuration.md),
normally `~/.lmx/config.json`, or the process environment. Zed's saved provider
credentials do not automatically configure Lemieux. The installed binary
reads no `.env` file. Separate named entries can select different configurations
with `"args": ["acp", "--config", "/absolute/path/to/config.json"]`.

For a source checkout, compile before connecting an editor. A launcher script
can change to the checkout and execute `mix lmx acp`; keep compilation output
off stdout and forward arguments with `"$@"`. Recompiling the same build while
an editor starts it can temporarily remove a beam. Use a separate build for
interactive qualification or wait for compilation to finish before reconnecting.

Zed's supported installation paths and configuration are documented in
[External Agents](https://zed.dev/docs/ai/external-agents). Public distribution
uses the ACP Registry; agent-server extensions are deprecated.

### Troubleshooting

- Agent missing from the menu: check that the entry is in the running Zed
  instance's user settings. A second macOS launch can reuse the existing
  application even when a different data directory was requested.
- Process fails to start: check the absolute executable path, its permissions,
  and `lmx help acp` in your terminal. For source runs, finish compilation first.
- Missing credentials: run `lmx acp setup` with the same `--config` flags as
  the editor entry, or supply credentials in the agent process's environment.
- Wrong files or working directory: open the intended project in Zed. A loaded
  session must match its recorded absolute working directory.
- Protocol errors: run `dev: open acp logs` in Zed and check the negotiated
  version. Record the Zed/lmx versions and OS/architecture when reporting a
  problem, and remove credentials and private source from shared logs.

The transport is newline-delimited JSON-RPC 2.0 on stdin/stdout. stdout is
reserved for packets. Each input frame is limited to 1 MiB; a connection owns at
most 16 open sessions. EOF cancels work, closes sessions and releases their
transcript locks. A partial frame at EOF is discarded.

## Supported contract

The implementation follows the upstream
[ACP schemas](https://github.com/agentclientprotocol/agent-client-protocol/tree/main/schema).
Initialization negotiates version 1 or 2; v2 remains a draft. Higher versions
negotiate down to 2, version 0 receives an unsupported-version error, and
malformed versions are rejected. Terminal setup is advertised only when the
client supports terminal authentication and the host uses a configuration file.

| Operation | Behavior |
| --- | --- |
| `session/new` | Requires an existing absolute `cwd`; connects explicitly supplied stdio MCP servers. |
| `session/list` | Reads durable user conversations, 50 per page; optional `cwd` filter and opaque cursor. |
| `session/load` (v1) | Loads a closed session or reuses an idle attached session; replays retained conversation before replying. |
| `session/resume` | Reopens a closed session under current host authority or reuses an idle attached one, with matching `cwd` and MCP configuration. Version 2 replays only for `replayFrom: {type: "start"}` and supplies current state before replying. |
| `session/prompt` | Accepts text and resource links; unsupported content is rejected before a model request. Resource links become named references for the model, without an automatic external fetch. |
| `session/update` | Streams text/thinking and tool activity. Version 2 also sends message replacement and foreground state updates. |
| `session/request_permission` | Parks an actual tool call. Only a correlated `allow_once` response authorizes it. Rejection, malformed responses and cancellation grant nothing. |
| `session/cancel` / `session/close` | Cancels work; close also releases the transcript lock. Late permission replies are discarded. |
| `session/set_config_option` | Changes an offered model or reasoning setting through the native session API. Session setup returns `configOptions`; changes emit `config_option_update`. Busy or unsupported changes are rejected. |
| `elicitation/create` | Requests a form for native questions when the client advertises form support. Missing, declined or cancelled responses grant no consent. |
| `fs/read_text_file` / `fs/write_text_file` (v1) | Uses advertised client methods for text access inside the existing host filesystem policy. |

Version 1 holds the prompt response until completion and returns `stopReason`.
Version 2 replies with the persisted user `messageId` when accepted, echoes
that message, and reports completion with `state_update: idle`. Clients must
use their negotiated version's lifecycle. There is no automatic retry of a
prompt that failed. Version 1 rejects busy prompts. Version 2 holds up to 16
additional prompts until current work ends, replies only after insertion, and
cancels uninserted prompts when the foreground work is cancelled.

Tool updates include kinds, file locations, execution states and readable
results. File-tool writes report diffs when both sides fit within 64 KiB of
valid text. Shell-command edits are outside this diff capture.

### Editor filesystem behavior

For v1 clients advertising filesystem support, native file tools can read
unsaved editor text and write through the editor. The existing sandbox remains
outside the adapter: hidden paths, read-only restrictions, symlink confinement,
and normal tool approvals still apply. A failed editor operation is returned
as an error; it is never retried as a local disk write.

Existing UTF-8 text files up to 512 KiB use client reads. Directory, binary,
missing-file and larger-file reads retain the local behavior; large files keep
streaming. New writes use the client when write support is advertised. Hosts
with a custom environment keep that environment. Draft v2 has no v1 filesystem
methods; its tools use the host environment.

The adapter does not advertise images, audio, embedded resource contents,
HTTP/SSE MCP transport, additional roots, client terminal delegation, or session
deletion. Shell tools run through the host environment. Unsupported replay cursors are
rejected. This is protocol qualification with local fixtures; individual
editor releases still need interactive testing before claiming compatibility.

## Optional Lemieux extensions

Version 1 initialization advertises `_meta.lemieux`; version 2 uses the
namespaced key `_meta["com.github.houllette.lemieux/capabilities"]`.
Both describe `question`, `steer`, `fork` and `configure`. To receive legacy
questions, the client sets `capabilities._meta.lemieux.question: true`
(version 1: `clientCapabilities`). The agent sends a JSON-RPC request named
`_lemieux/question` containing `sessionId` and the native questionnaire. The
client returns `{answer: "text"}` or the structured questionnaire answer.
Standard form elicitation takes precedence when supported. Unsupported clients
receive no question request; the tool records that no
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
this endpoint. Standard `configOptions` also expose model and reasoning choices.

## Offline editor and protocol qualification

The test fixture drives the real session loop with `Lemieux.Providers.Scripted`.
It makes no hosted model request. Compile it before attaching an editor:

```sh
MIX_ENV=test mix compile --warnings-as-errors
```

Configure an editor to run `mix` from the checkout with arguments
`["run", "--no-compile", "--no-deps-check", "test/fixtures/acp_agent.exs"]`,
`MIX_ENV=test`, and `LMX_ACP_TEST_SESSIONS` naming a disposable transcript
directory. A wrapper should change to the checkout before invoking Mix.
Use a separate compiled build if developing while the fixture is open.

The fixture accepts these prompts:

| Prompt | Behavior |
| --- | --- |
| `hello` | Streams a fixed response. |
| `lmx-acp:read` | Reads `example.txt`. |
| `lmx-acp:edit` | Replaces `before` with `after` in `example.txt`, through normal approval. |
| `lmx-acp:write` | Creates `created.txt`. |
| `lmx-acp:shell` | Runs a fixed `printf` command through normal approval. |
| `lmx-acp:question` | Asks a native question. |
| `lmx-acp:wait` | Holds a response for cancellation testing. |

Create `example.txt` containing `before` in a disposable workspace. Record the
editor/lmx versions, negotiated protocol and platform while checking:

1. Agent discovery, startup, streaming, and model/reasoning selectors.
2. File reads, unsaved text reads where supported, edits and displayed diffs.
3. Approval and rejection, including proof that rejection leaves files alone.
4. Questions, cancellation during work, and late permission/filesystem replies.
5. Thread restoration, editor restart, history import and transcript locks.
6. Resource links and configured stdio MCP forwarding.
7. Disconnect cleanup and useful startup/protocol errors.

For independent protocol checks, the experimental
[ACP TCK](https://agentclientprotocol.com/libraries/testing) can launch the same
fixture. Pin the TCK revision; a passing run is not official ACP certification:

```sh
acp_sessions="$(mktemp -d)"
LMX_ACP_TEST_SESSIONS="$acp_sessions" uvx \
  --from git+https://github.com/agentclientprotocol/acp-tck@f050441441ca4faafd1d4e58761125304d06743d \
  acp-tck --cancel-prompt __lmx_acp_wait__ --report-json /tmp/lmx-acp-v1.json \
  -- env MIX_ENV=test mix run --no-compile --no-deps-check test/fixtures/acp_agent.exs
```

Repeat with `--protocol-version 2` for the draft contract. Review failed,
skipped and unexercised requirements separately. Keep reports outside the
repository. Packaged release qualification also runs provider-free ACP
handshakes through the real launcher in `test/release_stdin_smoke.py`.

## ACP Registry distribution

Registry publication follows release qualification. The repository includes a
metadata generator and a monochrome icon; it does not claim a registry listing.
After releasing a version containing this integration, obtain its verified
`SHA256SUMS` and run:

```sh
python3 scripts/acp_registry.py --version X.Y.Z \
  --checksums /path/to/SHA256SUMS --output /tmp/lmx-registry
```

This prepares `lemieux/agent.json` and `lemieux/icon.svg` with immutable release
URLs, checksums and each archive's actual launcher. It declares only platforms
present in the checksums. Confirm the archives and terminal setup on every
declared platform, then run the upstream schema/distribution/authentication
checks and submit the entry according to the
[registry contribution guide](https://github.com/agentclientprotocol/registry/blob/main/CONTRIBUTING.md).
Registry submission and installation testing require the released artifacts;
the generator does not publish them or establish compatibility on its own.
