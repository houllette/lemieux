# MCP tools and authorization

The [Model Context Protocol](https://modelcontextprotocol.io) (MCP) is a
standard way for a separate program, an MCP server, to offer tools, prompts
and resources to an agent. Lemieux has its own MCP client in the library. It
talks to servers over stdio (a local command) and over HTTP.

The host — `lmx`, or an application that embeds Lemieux — owns connection
processes, credentials, approval and lifecycle. Adding the library starts no
server and no discovery process. In `lmx`, servers come from four places:

- a file you name with `--mcp-config FILE`;
- your own `"mcp_servers"` in `~/.lmx/config.json`, which `lmx mcp import`
  and the terminal UI's `/mcp` panel fill;
- the repository's `.mcp.json`, once you trust it
  ([Trusting repository servers](#trusting-repository-servers));
- a plugin you selected ([Configuration](configuration.md)).

An embedding host passes servers through the
[embedding API](embedding.md#mcp-servers).

## Add a server to lmx

Any one of these adds a server:

- In the terminal UI, type `/mcp`, press `a`, and answer the questions.
  The server is saved to your own `"mcp_servers"` unless you choose the
  repository's `.mcp.json`.
- Copy the servers you already set up for Claude Code or Codex:
  `lmx mcp import claude` or `lmx mcp import codex`
  ([Importing servers](#importing-servers-from-claude-code-and-codex)).
- Write them into `~/.lmx/config.json` yourself. A `url` means an HTTP
  server, a `command` a local one that `lmx` starts:

  ```json
  {
    "mcp_servers": {
      "docs": {"url": "https://mcp.example.com/mcp"},
      "tracker": {
        "command": "/path/to/tracker-mcp",
        "args": ["--stdio"],
        "env": {"TRACKER_TOKEN": "${TRACKER_TOKEN}"}
      }
    }
  }
  ```

Your own servers start without asking. `lmx mcp list` names them and the
repository's, and `/mcp` in the terminal UI shows each server's state and
tools. An HTTP server that wants OAuth comes up as needing sign-in;
reconnect it from the `/mcp` panel to sign in with your browser, once
([Manage connections in the TUI](#manage-connections-in-the-tui)).

## Configuration files and sources

Servers are read from an object of names to configurations, under
`mcpServers` or bare — the shape Claude Code writes. The transport is
Claude's `"type"` (`stdio`, `http`, or legacy `sse`) when given, Lemieux's own
`"transport"` when that is given (it wins), and otherwise inferred: a `url`
means HTTP, a `command` stdio. `Lemieux.MCP.Config.put_server/2` writes
`"type"`, so a file both clients share stays readable by both.

Legacy SSE servers are refused with directions: most that offered SSE also
serve Streamable HTTP, usually at `/mcp` instead of `/sse`.

Each server is marked with where it came from — `"project"` (a repository's
`.mcp.json`), `"personal"` (a person's own settings, or an import),
`"explicit"` (a file named on the command line) or `"plugin"`. A project
configuration may not read a credential-shaped variable through `${VAR}`
unless the host allows it by name. Credential-shaped means a name containing
`KEY`, `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD`, in any letter case: a
checkout's `.mcp.json` asking for `${ANTHROPIC_API_KEY}` in a header of a
server of its choosing would otherwise send the key there when the
repository was opened. `${VAR:-default}` is accepted, as in Claude Code.
Variables are expanded only when a server connects, so a transcript records
`${GITHUB_TOKEN}`, never the token.

### Importing servers from Claude Code and Codex

`lmx mcp import claude` copies Claude Code's user-scope servers, the
top-level `mcpServers` of `~/.claude.json`, into your `"mcp_servers"`, where
they start in every session as your own. It does not copy local-scope servers,
the ones `claude mcp add` creates by default under `projects.<path>` for one
project: Claude Code starts those only in that project, often with its
credentials. The command names the ones it left out for the current
directory (or `--project DIR`); to use one with `lmx`, add it to that
repository's `.mcp.json` or pass it with `--mcp-config`.

`lmx mcp import codex` copies Codex's `[mcp_servers.*]` tables from
`~/.codex/config.toml`, including their timeouts and bearer-token variables.
A server already in your config keeps what you wrote there. Importing needs a
config file, so `--config none` refuses it.

In the library, `Lemieux.MCP.Config.claude_code/2` reads Claude Code's user
servers, plus one project's local servers when given `project:`;
`Lemieux.MCP.Config.claude_code_local/2` reads only the local ones, and
`Lemieux.MCP.Config.codex/1` reads Codex's. All of them mark what they read
as personal.

## Trusting repository servers

`Lemieux.MCP.Trust` records a person's decision about a repository's servers,
keyed by the directory holding the configuration and a digest of what the
servers run and where they connect. Any change to a command, argument, URL,
header or environment entry is a new configuration and asks again. A declined
configuration is remembered as declined.

`Lemieux.Extensions.MCP` with `trust: dir` starts a repository's servers only
when they are trusted and unchanged; otherwise it holds them back with a
notice, and `Lemieux.Extensions.MCP.project_trust/3` returns what to show:
each server's name, transport, command or URL, and the names of the
environment variables it reads. The variables a person saw and trusted are
what `Lemieux.MCP.Trust.allowed_env/3` returns for `:allow_env`. A server
that starts without a person having seen it (a named file, or a repository
trusted with `trusted?: true`) is announced first, stdio and HTTP alike (the
HTTP notice names the host, not the URL). One a stored decision covers is
not: the prompt that recorded it showed each server.

A server of a person's own, `"personal"` or `"explicit"`, replaces the
repository's server of the same name. The repository's is dropped before
trust is asked about, so a prompt never asks about a server that will not
run and a session never sees two servers with one name; `project_trust/3`
takes the names to leave out as `:except`. A host that asks must pass them: a
decision is one digest over the servers asked about, and one recorded over
the whole file never matches the set the extension gates, which then holds
the repository's servers as changed on every start.

A session runs one server per name, whatever added it.
`Lemieux.Harness.append_mcp_servers/2` keeps the first configuration of a
name and adds a notice naming the one it left out. Extensions append in
order, so the servers closest to the person come first: a named file's, then
the person's own, then the repository's, then a plugin's
(`Lemieux.Extensions.Workspace`). A plugin's servers are named
`plugin_<plugin>_<server>`, as Claude Code names them, so they share a name
with another server only by design, and a plugin's hooks and permission rules
name its tools as they do in Claude Code.

In `lmx` the decisions live in your state directory
(`~/.lmx/trusted-mcp.json`). The terminal UI asks the first time it sees an
untrusted or changed file; `lmx mcp trust --yes` records the same decision
from a script, `lmx mcp untrust` forgets it, `--project-mcp` trusts the file
for one run, `--no-project-mcp` (or `LMX_PROJECT_MCP=0`) never starts it, and
`lmx run` never asks. Your own servers start without asking. The
[trust model](../SECURITY.md#what-lmx-trusts-by-default) puts this beside
`lmx`'s other defaults.

## Connecting, budgets and cancellation

`Lemieux.MCP.connect_server/2` connects one server and is what a host runs in
parallel; `connect_report/2` connects a list. Each server's budgets can be set
in its configuration, in milliseconds:

| Key | Default | Measures |
| --- | --- | --- |
| `startup_timeout` | 60s | the handshake and first tool listing |
| `timeout` | 30s | every other request, and tool calls when `tool_timeout` is unset |
| `tool_timeout` | 10 min | a tool call's **silence**: progress notifications restart it |

Over stdio and HTTP several calls to one server can be in flight. A call whose
caller goes away — the turn was cancelled, its deadline passed — is withdrawn
with `notifications/cancelled`, and the server is free for the next call
rather than held until it answers. A server's `ping` is answered, and
`notifications/tools/list_changed` makes the client list the tools again and
tell the session.

With `interactive_auth: false`, a server whose OAuth needs somebody at a
browser is reported as `{:needs_auth, info}` rather than opening a page and
holding startup; a stored or refreshable token is still used. The host
finishes the flow later, interactively.

### What a stdio server inherits

A stdio server runs with the VM's environment as the host corrected it
(`Lemieux.Environment.Inherited`), less what the `:credentials` policy
withholds (`Lemieux.Environment.Credentials`), and its command is looked up
on the `PATH` it will see. Under the installed `lmx` that is the environment
you started `lmx` in, your own `PATH` included, so a server started as
`erl`, `elixir` or `mix` runs your installation rather than the release's
([What commands inherit](configuration.md#what-commands-inherit)). `lmx`
withholds every variable whose name contains `KEY`, `TOKEN`, `SECRET`,
`PASSWORD` or `PASSWD`, except the names in `"credential_allowlist"`;
`"scrub_credentials": false` turns that off. The rule reads names, not
values, so a secret under another name (`DATABASE_URL` with a password in
it) still passes. Variables the server's own `env` names are always passed.

Every stdio server also gets `CLAUDE_PROJECT_DIR`, the directory the session
started in, unless its configuration sets it: Claude Code exports it, and a
server written for Claude Code finds its project files through it. A
plugin's stdio servers also get `CLAUDE_PLUGIN_ROOT`, the plugin's directory,
and `CLAUDE_PLUGIN_DATA`, its persistent data directory, and both are
substituted wherever `${CLAUDE_PLUGIN_ROOT}` or `${CLAUDE_PLUGIN_DATA}`
appears in the server's configuration. The data directory is
`~/.lmx/plugin-data/<id>`, where the id is the plugin's name, or
`NAME@MARKETPLACE`, with every character other than a letter, digit, `_` or
`-` replaced by `-`. It is created, readable only by you, when a server or
hook that is told about it first starts. Under `--config none` without
`LMX_HOME` it is a fresh temporary directory for that run.

## Tool names

Provider APIs accept tool names matching `^[a-zA-Z_][a-zA-Z0-9_]*(-…)*$` of at
most 64 characters, and MCP allows much more. A qualified name
(`server__tool`) that is already valid is offered unchanged; one that is not is
rewritten into the allowed alphabet, shortened to fit and given a hash of the
original, so two originals that sanitise alike never share a name. Calls are
routed by the server and the tool's own name, not by parsing the offered name.
Renamed and left-out tools are reported in the client's `info/1` notices. A
tool whose input schema lacks `"type"` is read as the object the specification
requires; one whose arguments are not an object is left out with a reason.

## Prompts and resources

`Lemieux.MCP.list_prompts/1`, `prompt/3`, `list_resources/1` and
`resource/2` read a server's prompts and resources; `prompt_command/2` names a
prompt as a slash command (`mcp__server__prompt`). A server that did not
declare the capability has none and is not asked. In the terminal UI,
`/prompts` lists them, and `/mcp__SERVER__PROMPT [ARGS]` (named `name=value`
arguments or positional ones) sends the prompt as your message.

A server that offers only prompts or resources, and no tools, connects and is
listed like any other: `/prompts` finds servers through
`Lemieux.Session.mcp_clients/2`, not through their tools.

A resource can be attached to a prompt as `@server:uri`, for example
`@docs:file:///guide.md`: the session reads it from that server when the prompt
is sent, numbers it like a file, and spends the same attachment budget files
do. A server that is not connected, or a resource it refuses, becomes an
attachment that says so. The `@` picker offers each server's resources beside
files once you type after the `@`; see `Lemieux.Reference` for the grammar,
which reads `@README.md: it says` as the file, and quotes a path that has a
colon in it (`@"a:b.txt"`).

## Manage connections in the TUI

`/mcp` opens the server panel directly. Connection progress (connecting,
connected, needs sign-in, failed), discovered tools, reconnect actions and
errors stay in the panel. Servers connect in the background when a session
starts, with `interactive_auth: false`, so a server that needs OAuth consent is
shown as needing sign-in instead of holding startup; reconnecting it from the
panel runs the browser flow. The panel's add form (`a`) saves to your own
`"mcp_servers"` by default, or to the repository's `.mcp.json` if you
choose. It stores a secret-looking header or environment value as a
`${NAME}` reference, and names the variables to export before the next
session. `/mcp add PATH` adds the servers in a configuration file to the
current session only, and `/mcp remove NAME` takes one out of it. Saved
`.mcp.json` changes preserve unrelated configuration. Remote descriptors
retain their origin and pass through the same
[governed tool contract](tool-contracts.md#mcp-preservation) as native tools.
An advertised tool is not permission to execute it.

## OAuth ownership and security

`Lemieux.MCP.Auth` owns the authorization protocol and accepts host-supplied
credential storage. `Lemieux.CLI.OAuth` owns the interactive browser and loopback
callback. Embedded and headless hosts supply their own interaction or reuse an
already-authorized store. A browser prompt does not grant account entitlement.

The implemented flow preserves these boundaries:

- Discover protected-resource metadata from the challenge and required
  well-known fallbacks; validate authorization-server metadata and issuer.
- Select pre-registered credentials, advertised client metadata support, or
  stored/new dynamic registration as supported by server metadata.
- Use PKCE `S256`, validate state and issuer, and bind authorization and token
  requests to the resource. A mismatched callback must disclose no response
  contents.
- Key client registration by issuer, and access/refresh tokens by issuer **and
  resource**. Preserve those stamps when saving; never send a token to another
  resource merely because it shares an issuer.
- Keep credential files readable only by their owner. A failed refresh clears
  the stale token and asks for authorization again. Refresh/retry is bounded;
  an insufficient-scope challenge requests the union of existing and newly
  required scope.

The callback listens on a fixed loopback port, 8642 unless
`--oauth-callback-port` says otherwise, so a person on a machine with no
browser can forward it (`ssh -L 8642:localhost:8642 devbox`) and open the
printed link on their own machine. An authorization server that offers no
dynamic registration takes a pre-registered client with
`--oauth-client-id ISSUER=CLIENT_ID`. See
[OAuth troubleshooting](troubleshooting.md#mcp-oauth-cannot-return-to-the-callback)
for the CLI recipe. Browser navigation and redirect receipt remain host
concerns rather than a web-server dependency in the core.

### Where tokens are kept

`lmx` keeps MCP OAuth tokens in `~/.lmx/mcp-credentials.json`, beside the
rest of its state, unless `--credentials FILE` or `LMX_CREDENTIALS` names
another file. The file is created readable only by you (`0600`), and a
directory `lmx` creates for it is `0700`. It is not encrypted: it protects
the tokens from other users of the machine, not from programs running as
you. `--sandbox` hides it from commands and file tools.

The library's own default store, for an embedding host that names no file,
is `~/.lemieux/credentials.json` (`Lemieux.MCP.Auth.Store.File.default_path/0`).
If that file holds tokens and `lmx`'s store is still empty, the first time
`lmx` uses its default store it moves the file there: the tokens are written
to `~/.lmx/mcp-credentials.json` and the old file is deleted, not kept as a
copy. Another host on the same machine that relied on the library default
then finds its tokens gone and authorizes its servers again. A file named
with `--credentials` or `LMX_CREDENTIALS` gets nothing moved into it, and an
old file that does not parse is left where it is.

A host that needs more than a file implements `Lemieux.MCP.Auth.Store` over
a keychain.

### What has been tested

The flow is covered by offline tests against local fixture servers. Against
hosted servers, discovery, client registration and the PKCE- and
resource-bound authorization URL have been exercised; a completed consent,
an authorized call, token reuse after a restart and a refresh with a real
account have not been recorded yet. Registration choices and headless support
differ between hosted servers, so check yours. The [roadmap](roadmap.md)
tracks the remaining work.

## On-demand schema exposure

Apply `Lemieux.Extensions.MCPDiscovery` to a harness to keep large remote schemas
out of the initial model request. `mcp_discover` searches the current authorized
catalog, then enables a bounded list of exact qualified names for subsequent
requests. Ordinary calls retain their remote descriptors, approval policy,
deadlines, budget admission and transcript receipts. Undiscovered calls are
denied even if the model guesses their names.

Options are `max_tools: 8` (1–32), `ttl_ms: 300_000`, `pinned: []` for always
visible names, and `mode`: `:on` (the default when applied directly) always
hides remote schemas; `:auto` hides them only while they would cost more than
`threshold_bytes` of the request (a tenth of `context_window` tokens at four
bytes a token when given, else 40,000) and otherwise offers every schema and
leaves `mcp_discover` out; `:off` applies nothing. Each enable replaces the
selection. Expiration, descriptor changes and a new host binding invalidate
selections. Reapply the extension on resume and after changing
authentication; credentials and executors are never cached in the transcript.
Selection does not mutate the busy session catalog.

`lmx` applies it in `:auto` mode whenever it attaches MCP servers, so a few
small servers are offered as they are and a large catalog is searched on
demand. The threshold is a tenth of `--context-window` (or
`"context_window"`) when you set one, and 40,000 bytes otherwise.
`"mcp_discovery": "on"`, `"off"` or `"auto"` in `~/.lmx/config.json`
chooses the mode.

This is deferred schema exposure, not lazy server startup. Existing MCP
connection ownership and list-tools behavior remain in force. A server that
announces a changed tool list is listed again by its client, and a session
replaces that server's tools with the new list. This avoids introducing a
second remote execution path or a stale global discovery cache.
